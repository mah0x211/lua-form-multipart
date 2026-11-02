local testcase = require('testcase')
local assert = require('assert')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local multipart = require('form.multipart')
local prefixes = {}

local function files_with_prefix(prefix)
    local found = {}
    local err = readdir('.', function(name)
        if name:sub(1, #prefix + 1) == prefix .. '_' then
            found[#found + 1] = name
        end
    end)
    assert.is_nil(err)
    return found
end

local function unused_prefix()
    local file, _, pathname = assert(mkstemp('./decode_cleanup_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    local prefix = pathname:gsub('^%./', '')
    prefixes[#prefixes + 1] = prefix
    return prefix
end

function testcase.before_each()
    -- Cleanup must happen before decode returns, without help from finalizers.
    collectgarbage('stop')
end

function testcase.after_each()
    for _, prefix in ipairs(prefixes) do
        for _, pathname in ipairs(files_with_prefix(prefix)) do
            os.remove(pathname)
        end
    end
    prefixes = {}
    collectgarbage('restart')
end

local header = '--b\r\nContent-Disposition: form-data; name="foo"; filename="x"' ..
    '\r\n\r\n'

function testcase.decode_removes_incomplete_file_on_reader_failure()
    for _, raises in ipairs({ false, true }) do
        local prefix = unused_prefix()
        local first = true
        local reader = {
            read = function()
                if first then
                    first = false
                    return header .. 'first line\r\nunfinished'
                end
                assert.not_empty(files_with_prefix(prefix))
                if raises then error('reader failed') end
                return nil, 'reader failed'
            end,
        }
        local form, err = multipart.decode(reader, 'b', prefix)
        assert.is_nil(form)
        assert.match(tostring(err), 'reader failed')
        assert.empty(files_with_prefix(prefix))
    end
end

function testcase.decode_removes_incomplete_file_on_truncation_or_size_error()
    for _, case in ipairs({
        { header .. 'unfinished', false, 'insufficient multipart/form-data' },
        { header .. 'first\r\nunfinished', false, 'insufficient multipart/form-data' },
        { header .. 'payload\r\n--b--', 3, 'multipart body too large' },
    }) do
        local prefix = unused_prefix()
        local form, err = multipart.decode(case[1], 'b', prefix, case[2] or nil)
        assert.is_nil(form)
        assert.match(tostring(err), case[3])
        assert.empty(files_with_prefix(prefix))
    end
end

function testcase.decode_removes_completed_and_incomplete_files_together()
    for _, name in ipairs({ 'foo', 'bar' }) do
        local prefix = unused_prefix()
        local input = header .. 'complete\r\n--b\r\n' ..
            'Content-Disposition: form-data; name="' .. name .. '"; filename="y"' ..
            '\r\n\r\nunfinished'
        local form, err = multipart.decode(input, 'b', prefix)
        assert.is_nil(form)
        assert.match(tostring(err), 'insufficient multipart/form-data')
        assert.empty(files_with_prefix(prefix))
    end
end
