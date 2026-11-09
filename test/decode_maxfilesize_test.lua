local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local multipart = require('form.multipart')
local unpack = table.unpack or unpack
local files = {}

local function prefix()
    local file, _, pathname = assert(mkstemp('./test_limit_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    return pathname
end

local function reader(input)
    local pos = 1
    return {
        read = function(_, n)
            local s = input:sub(pos, pos + n - 1)
            pos = pos + #s
            if #s == 0 then return nil end
            return s
        end,
    }
end

local function file_body(boundary, payload)
    return '--' .. boundary .. '\r\n' ..
        'Content-Disposition: form-data; name="file"; filename="x"\r\n' ..
        '\r\n' .. payload .. '\r\n--' .. boundary .. '--'
end

local function remember_files(form)
    for _, parts in pairs(form) do
        for _, part in ipairs(parts) do
            if part.file then files[#files + 1] = part end
        end
    end
end

function testcase.after_each()
    for _, part in ipairs(files) do
        if io.type(part.file) == 'file' then part.file:close() end
        os.remove(part.pathname)
    end
    files = {}
    -- Collect failed fixtures whose temporary files are finalized by GC.
    collectgarbage('collect')
    collectgarbage('collect')
end

function testcase.decode_accepts_exact_file_limit_for_whole_input()
    for _, boundary in ipairs({ 'b', string.rep('x', 70), 'a b' }) do
        for _, payload in ipairs({ '', 'abc', 'a\nb', 'a\r\nb' }) do
            local form, err = multipart.decode(file_body(boundary, payload), boundary, prefix(), #payload)
            assert.is_nil(err)
            remember_files(form)
            assert.equal(form.file[1].file:read('*a'), payload)
        end
    end
end

function testcase.decode_file_limit_is_independent_of_reader_chunks()
    for _, boundary in ipairs({ 'b', string.rep('x', 70), 'a b' }) do
        for _, payload in ipairs({ '', 'abc', 'a\nb', 'a\r\nb' }) do
            for _, chunksize in ipairs({ 1, 2, 3, 4, 8, 16, 4096 }) do
                local input = file_body(boundary, payload)
                local form, err = multipart.decode(reader(input), boundary, prefix(), #payload, chunksize)
                assert.is_nil(err)
                remember_files(form)
                assert.equal(form.file[1].file:read('*a'), payload)
            end
        end
    end
end

function testcase.decode_negative_file_limits_allow_only_empty_files()
    local input = file_body('b', '')
    for _, limit in ipairs({ -1, -100 }) do
        local opts = { filetmpl = prefix(), maxfilesize = limit, chunksize = 2 }
        for _, args in ipairs({ { n = 1, opts }, { n = 3, prefix(), limit, 2 } }) do
            for _, source in ipairs({ input, reader(input) }) do
                local form, err = multipart.decode(source, 'b', unpack(args, 1, args.n))
                assert.is_nil(err)
                remember_files(form)
                assert.equal(form.file[1].file:read('*a'), '')
            end
        end
        assert.equal(opts.maxfilesize, limit)
    end
end

function testcase.decode_negative_file_limits_reject_nonempty_files()
    local input = file_body('b', 'x')
    for _, limit in ipairs({ -1, -100 }) do
        local opts = { filetmpl = prefix(), maxfilesize = limit, chunksize = 2 }
        for _, args in ipairs({ { n = 1, opts }, { n = 3, prefix(), limit, 2 } }) do
            for _, source in ipairs({ input, reader(input) }) do
                local form, err = multipart.decode(source, 'b', unpack(args, 1, args.n))
                assert.is_nil(form)
                assert.equal(errlib.typeof(err), multipart.EDECODE)
                assert.not_nil(errlib.is(err, errno.EFBIG))
                assert.match(tostring(err), 'multipart body too large')
            end
        end
        assert.equal(opts.maxfilesize, limit)
    end
end

function testcase.decode_negative_file_limits_do_not_limit_text()
    local input = '--b\r\nContent-Disposition: form-data; name="text"\r\n\r\n' ..
        'value\r\n--b--'
    for _, limit in ipairs({ -1, -100 }) do
        for _, source in ipairs({ input, reader(input) }) do
            local form, err = multipart.decode(source, 'b', {
                maxfilesize = limit, chunksize = 2,
            })
            assert.is_nil(err)
            assert.equal(form.text[1].data, 'value')
        end
    end
end

function testcase.decode_rejects_file_limit_exceeded_across_chunks()
    for _, payload in ipairs({ 'abcd', 'a\r\nb\r\nc' }) do
        for _, chunksize in ipairs({ 1, 2, 4, 8, 4096 }) do
            local form, err = multipart.decode(reader(file_body('b', payload)), 'b', prefix(), 3, chunksize)
            assert.is_nil(form)
            assert.match(tostring(err), 'multipart body too large')
        end
    end
end

function testcase.decode_file_limit_does_not_limit_text_or_total_file_size()
    local input = '--b\r\nContent-Disposition: form-data; name="text"\r\n' ..
        '\r\nlong text value\r\n--b\r\n' ..
        'Content-Disposition: form-data; name="file"; filename="a"\r\n' ..
        '\r\nabc\r\n--b\r\n' ..
        'Content-Disposition: form-data; name="file"; filename="b"\r\n' ..
        '\r\ndef\r\n--b--'
    for _, chunksize in ipairs({ 1, 2, 8, 4096 }) do
        local form, err = multipart.decode(reader(input), 'b', prefix(), 3, chunksize)
        assert.is_nil(err)
        remember_files(form)
        assert.equal(form.text[1].data, 'long text value')
        assert.equal(form.file[1].file:read('*a'), 'abc')
        assert.equal(form.file[2].file:read('*a'), 'def')
    end
    local form, err = multipart.decode('--b\r\nContent-Disposition: form-data; name="text"\r\n' ..
        '\r\nlong text value\r\n--b--', 'b', nil, 0)
    assert.is_nil(err)
    assert.equal(form.text[1].data, 'long text value')
end

function testcase.decode_file_limit_excludes_boundary_padding()
    local input = '--b\r\nContent-Disposition: form-data; name="file"; filename="a"\r\n' ..
        '\r\na\r\n--b' .. string.rep(' ', 20) .. '\t\r\n' ..
        'Content-Disposition: form-data; name="file"; filename="b"\r\n' ..
        '\r\nb\r\n--b--'
    for _, chunksize in ipairs({ 1, 2, 4, 16 }) do
        local form, err = multipart.decode(reader(input), 'b', prefix(), 1, chunksize)
        assert.is_nil(err)
        remember_files(form)
        assert.equal(form.file[1].file:read('*a'), 'a')
        assert.equal(form.file[2].file:read('*a'), 'b')
    end
end

function testcase.decode_stops_when_buffered_file_payload_exceeds_limit()
    for _, case in ipairs({
        { payload = '1234567890', maxfilesize = 3 },
        { payload = 'a\r\n1234567890', maxfilesize = 6 },
    }) do
        local calls = 0
        local input = '--b\r\nContent-Disposition: form-data; name="file"; filename="x"\r\n' ..
            '\r\n' .. case.payload
        local source = {
            read = function()
                calls = calls + 1
                if calls == 1 then return input end
                error('must not read more oversized file data')
            end,
        }
        local form, err = multipart.decode(source, 'b', prefix(), case.maxfilesize)
        assert.is_nil(form)
        assert.match(tostring(err), 'multipart body too large')
        assert.equal(calls, 1)
    end
end
