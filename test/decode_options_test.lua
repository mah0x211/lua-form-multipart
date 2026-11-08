local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local multipart = require('form.multipart')
local unpack = table.unpack or unpack
local files = {}

local body = '--b\r\nContent-Disposition: form-data; name="text"\r\n\r\nvalue\r\n--b--'
local file_body = '--b\r\nContent-Disposition: form-data; name="upload"; filename="a"\r\n\r\nabc\r\n--b--'

local function reader(input)
    return {
        pos = 1,
        requests = {},
        read = function(self, n)
            self.requests[#self.requests + 1] = n
            local s = input:sub(self.pos, self.pos + n - 1)
            self.pos = self.pos + #s
            if #s > 0 then return s end
        end,
    }
end

function testcase.after_each()
    for _, part in ipairs(files) do
        if io.type(part.file) == 'file' then part.file:close() end
        os.remove(part.pathname)
    end
    files = {}
end

function testcase.decode_options_defaults_and_legacy_nil_arguments()
    local opts = {}
    for _, args in ipairs({
        { n = 0 },
        { n = 1 },
        { n = 3 },
        { n = 3, [3] = 7 },
        { n = 1, opts },
    }) do
        for _, source in ipairs({ body, reader(body) }) do
            local form, err = multipart.decode(source, 'b', unpack(args, 1, args.n))
            assert.is_nil(err)
            assert.equal(form.text[1].data, 'value')
        end
    end
    assert.empty(opts)
end

function testcase.decode_ignores_arguments_after_legacy_chunksize()
    for _, extra in ipairs({ 0, false, 'invalid', {}, -1 }) do
        for _, source in ipairs({ body, reader(body) }) do
            local form, err = multipart.decode(source, 'b', nil, nil, 3,
                                              extra, { maxsize = 0 })
            assert.is_nil(err)
            assert.equal(form.text[1].data, 'value')
        end
    end
end

function testcase.decode_options_preserves_file_settings_without_mutation()
    local file, _, prefix = assert(mkstemp('./decode_options_XXXXXX'))
    file:close()
    assert(os.remove(prefix))
    local opts = {
        filetmpl = prefix,
        maxfilesize = 3,
        chunksize = 2,
        maxsize = #file_body,
    }
    for _ = 1, 2 do
        local source = reader(file_body)
        local form, err = multipart.decode(source, 'b', opts)
        assert.is_nil(err)
        local part = form.upload[1]
        files[#files + 1] = part
        assert.equal(part.pathname:sub(1, #prefix + 1), prefix .. '_')
        assert.equal(part.file:read('*a'), 'abc')
        assert.equal(source.requests[1], 2)
        for _, n in ipairs(source.requests) do assert.less_or_equal(n, 2) end
        assert.equal(opts.filetmpl, prefix)
        assert.equal(opts.maxfilesize, 3)
        assert.equal(opts.chunksize, 2)
        assert.equal(opts.maxsize, #file_body)
    end
end

function testcase.decode_options_applies_file_and_total_limits_independently()
    local form, err = multipart.decode(body, 'b', {
        maxfilesize = 0,
        maxsize = #body,
    })
    assert.is_nil(err)
    assert.equal(form.text[1].data, 'value')

    for _, case in ipairs({
        { opts = { maxfilesize = 2 }, message = 'multipart body too large' },
        { opts = { maxsize = #file_body - 1 }, message = 'maxsize' },
        { opts = { maxsize = 0 }, message = 'maxsize' },
    }) do
        form, err = multipart.decode(reader(file_body), 'b', case.opts)
        assert.is_nil(form)
        assert.equal(errlib.typeof(err), multipart.EDECODE)
        assert.not_nil(errlib.is(err, errno.EFBIG))
        assert.match(tostring(err), case.message)
    end
end

function testcase.decode_options_honors_reader_chunksize()
    local source = reader(body)
    local form, err = multipart.decode(source, 'b', { chunksize = 3 })
    assert.is_nil(err)
    assert.equal(form.text[1].data, 'value')
    assert.not_empty(source.requests)
    for _, n in ipairs(source.requests) do assert.equal(n, 3) end

    -- As with positional arguments, chunksize is unused for string input.
    form, err = multipart.decode(body, 'b', { chunksize = false })
    assert.is_nil(err)
    assert.equal(form.text[1].data, 'value')
end

function testcase.decode_options_preserves_reader_errors()
    for _, raises in ipairs({ false, true }) do
        local cause = errno.EIO:new('options reader failed')
        local source = {
            read = function()
                if raises then error(cause, 0) end
                return nil, cause
            end,
        }
        local form, err = multipart.decode(source, 'b', { maxsize = #body })
        assert.is_nil(form)
        assert.equal(errlib.typeof(err), multipart.EDECODE)
        assert.is_true(errlib.unwrap(err) == cause)
    end
end

function testcase.decode_options_invalid_values_raise_before_reading()
    for _, case in ipairs({
        { opts = { filetmpl = false }, message = 'filetmpl must be string' },
        { opts = { maxfilesize = -1 }, message = 'maxfilesize must be uint' },
        { opts = { chunksize = 0 }, message = 'chunksize must be positive integer' },
        { opts = { maxsize = '1' }, message = 'maxsize must be uint' },
    }) do
        local calls = 0
        local source = { read = function() calls = calls + 1 end }
        local ok, err = pcall(multipart.decode, source, 'b', case.opts)
        assert.is_false(ok)
        assert.match(tostring(err), case.message)
        assert.is_nil(errlib.is(err, multipart.EDECODE))
        assert.equal(calls, 0)
    end
end

function testcase.decode_interprets_multiple_optional_arguments_as_positional()
    for _, args in ipairs({
        { n = 1 },
        { n = 1, 'prefix' },
        { n = 3, nil, 1, 7 },
    }) do
        local calls = 0
        local source = { read = function() calls = calls + 1 end }
        local ok, err = pcall(multipart.decode, source, 'b', {},
                              unpack(args, 1, args.n))
        assert.is_false(ok)
        assert.match(tostring(err), 'filetmpl must be string')
        assert.is_nil(errlib.is(err, multipart.EDECODE))
        assert.equal(calls, 0)
    end
end

function testcase.decode_legacy_invalid_template_still_raises()
    for _, value in ipairs({ false, 1 }) do
        local ok, err = pcall(multipart.decode, body, 'b', value, nil)
        assert.is_false(ok)
        assert.match(tostring(err), 'filetmpl must be string')
        assert.is_nil(errlib.is(err, multipart.EDECODE))
    end
end

function testcase.decode_single_invalid_template_preserves_legacy_error()
    for _, value in ipairs({ false, 1 }) do
        local calls = 0
        local source = { read = function() calls = calls + 1 end }
        local ok, err = pcall(multipart.decode, source, 'b', value)
        assert.is_false(ok)
        assert.match(tostring(err), 'filetmpl must be string')
        assert.is_nil(errlib.is(err, multipart.EDECODE))
        assert.equal(calls, 0)
    end
end
