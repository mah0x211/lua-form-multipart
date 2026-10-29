local testcase = require('testcase')
local assert = require('assert')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local multipart = require('form.multipart')

local header = '--b\r\nContent-Disposition: form-data; name="foo"\r\n\r\n'
local body = header .. 'value\r\n--b--'

local function reader_for(chunks, err)
    local i = 0
    return {
        read = function()
            i = i + 1
            if chunks[i] then return chunks[i] end
            return nil, err
        end,
    }
end

local function unused_prefix()
    local file, _, pathname = assert(mkstemp('./decode_coverage_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    return pathname
end

local function files_with_prefix(prefix)
    prefix = prefix:gsub('^%./', '')
    local found = {}
    local err = readdir('.', function(name)
        if name:sub(1, #prefix + 1) == prefix .. '_' then
            found[#found + 1] = name
        end
    end)
    assert.is_nil(err)
    return found
end

function testcase.decode_reads_fragmented_multiline_values()
    local input = 'preamble\r\n' .. header .. 'first\r\nsecond\nthird' ..
        '\r\n--b \t\r\nContent-Disposition: form-data; name="bar"\r\n' ..
        '\r\nlast\r\n--b--\r\nepilogue'
    for _, chunksize in ipairs({ 1, 2, 3, 7, 32 }) do
        local pos = 1
        local reader = {
            read = function(_, n)
                local s = input:sub(pos, pos + n - 1)
                pos = pos + #s
                if #s == 0 then return nil end
                return s
            end,
        }
        local form, err = multipart.decode(reader, 'b', nil, nil, chunksize)
        assert.is_nil(err)
        assert.equal(form.foo[1].data, 'first\r\nsecond\nthird')
        assert.equal(form.bar[1].data, 'last')
    end
end

function testcase.decode_propagates_reader_errors_at_each_phase()
    for _, chunks in ipairs({
        {},
        { '--b\r\nContent-Disposition' },
        { header .. 'value' },
        { header .. 'value\r\n--b \t' },
        { body },
    }) do
        local form, err = multipart.decode(reader_for(chunks, 'reader stopped'), 'b')
        assert.is_nil(form)
        assert.match(tostring(err), 'reader stopped')
    end
end

function testcase.decode_rejects_truncated_input_at_each_phase()
    for _, chunks in ipairs({
        {},
        { '--b\r\nContent-Disposition' },
        { header .. 'value' },
        { header .. 'value\r\n--b \t' },
    }) do
        local form, err = multipart.decode(reader_for(chunks), 'b')
        assert.is_nil(form)
        assert.match(tostring(err), 'insufficient multipart/form-data')
    end
    local form, err = multipart.decode(reader_for({ '' }), 'b')
    assert.is_nil(form)
    assert.match(tostring(err), 'insufficient multipart/form-data')
end

function testcase.decode_rejects_invalid_headers_and_missing_names()
    local form, err = multipart.decode('--b\r\ninvalid-header\r\n\r\n', 'b')
    assert.is_nil(form)
    assert.match(tostring(err), 'invalid header')
    form, err = multipart.decode('--b\r\nContent-Type: text/plain\r\n\r\nx\r\n--b--', 'b')
    assert.is_nil(form)
    assert.match(tostring(err), 'does not contain a name parameter')
end

function testcase.decode_rejects_close_delimiter_before_first_part()
    local form, err = multipart.decode('--b--\r\n', 'b')
    assert.is_nil(form)
    assert.match(tostring(err), 'end of boundary found, but boundary not started')
end

function testcase.decode_reports_unavailable_temporary_directory()
    local prefix = unused_prefix()
    local input = '--b\r\nContent-Disposition: form-data; name="foo"; filename="x"' ..
        '\r\n\r\nx\r\n--b--'
    local form, err = multipart.decode(input, 'b', prefix .. '/file')
    assert.is_nil(form)
    assert.not_nil(err)
    assert.empty(files_with_prefix(prefix))
end

function testcase.decode_uses_filename_star_and_removes_file_after_collection()
    local prefix = unused_prefix()
    local input = '--b\r\nContent-Disposition: form-data; name="foo"; filename="old"; filename*="new"' ..
        '\r\n\r\npayload\r\n--b--'
    -- Return from the frame so no file or finalizer references remain on it.
    local pathname = (function()
        local form, err = multipart.decode(input, 'b', prefix)
        assert.is_nil(err)
        local part = form.foo[1]
        assert.equal(part.filename, 'new')
        assert.equal(part.file:read('*a'), 'payload')
        local file = assert(io.open(part.pathname))
        file:close()
        part.file:close()
        return part.pathname
    end)()
    collectgarbage('collect')
    collectgarbage('collect')
    local file = io.open(pathname)
    if file then file:close() end
    assert.is_nil(file)
    assert.empty(files_with_prefix(prefix))
end

function testcase.decode_rejects_files_exceeding_maxsize()
    for _, payload in ipairs({ 'abcdef', 'abcdefgh\r\nnext' }) do
        local prefix = unused_prefix()
        local input = '--b\r\nContent-Disposition: form-data; name="foo"; filename="x"' ..
            '\r\n\r\n' .. payload .. '\r\n--b--'
        local form, err = multipart.decode(input, 'b', prefix, 3)
        assert.is_nil(form)
        assert.match(tostring(err), 'multipart body too large')
        collectgarbage('collect')
        collectgarbage('collect')
        assert.empty(files_with_prefix(prefix))
    end
end

function testcase.decode_removes_completed_files_when_a_later_header_is_invalid()
    local prefix = unused_prefix()
    local input = '--b\r\nContent-Disposition: form-data; name="foo"; filename="x"' ..
        '\r\n\r\npayload\r\n--b\r\n' ..
        'Content-Disposition: form-data; name="bar"\r\n\r\nvalue\r\n--b\r\n' ..
        'invalid-header\r\n\r\n'
    local form, err = multipart.decode(input, 'b', prefix)
    assert.is_nil(form)
    assert.match(tostring(err), 'invalid header')
    assert.empty(files_with_prefix(prefix))
end

function testcase.decode_handles_reader_exceptions_after_completed_files()
    local prefix = unused_prefix()
    local input = '--b\r\nContent-Disposition: form-data; name="foo"; filename="x"' ..
        '\r\n\r\npayload\r\n--b--'
    local first = true
    local reader = {
        read = function()
            if first then first = false; return input end
            error('reader raised')
        end,
    }
    local form, err = multipart.decode(reader, 'b', prefix)
    assert.is_nil(form)
    assert.match(tostring(err), 'reader raised')
    assert.empty(files_with_prefix(prefix))
end

function testcase.decode_rejects_oversized_file_before_next_chunk()
    local prefix = unused_prefix()
    local input = '--b\r\nContent-Disposition: form-data; name="foo"; filename="x"' ..
        '\r\n\r\nabcdef'
    local form, err = multipart.decode(reader_for({ input, '\r\n--b--' }), 'b', prefix, 3)
    assert.is_nil(form)
    assert.match(tostring(err), 'multipart body too large')
    collectgarbage('collect')
    collectgarbage('collect')
    assert.empty(files_with_prefix(prefix))
end
