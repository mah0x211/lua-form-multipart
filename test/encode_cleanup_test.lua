local testcase = require('testcase')
local assert = require('assert')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local multipart = require('form.multipart')
local pathname

function testcase.before_all()
    local file, _
    file, _, pathname = assert(mkstemp('./test_encode_XXXXXX'))
    assert(file:write('content'))
    assert(file:close())
end

function testcase.after_all()
    if pathname then os.remove(pathname) end
end

local function descriptor_count()
    local n = 0
    local err = readdir('/dev/fd', function(name)
        if name ~= '.' and name ~= '..' then n = n + 1 end
    end)
    assert.is_nil(err)
    return n
end

function testcase.encode_pathname_header_errors_close_owned_handles()
    for _, fail_at in ipairs({ 1, 2, 3 }) do
        local part = {
            filename = 'x.txt', pathname = pathname,
            header = { ['X-Example'] = { 'value' } },
        }
        local calls = 0
        local before = descriptor_count()
        collectgarbage('stop')
        local ok, result, err = pcall(multipart.encode, { foo = { part } }, 'b', {
            write = function(_, s)
                calls = calls + 1
                if calls == fail_at then return nil, 'header write failed' end
                return #s
            end,
            writefile = function() error('writefile must not be reached') end,
        })
        local after = descriptor_count()
        collectgarbage('restart')
        -- Keep a failing implementation from leaking handles into other cases.
        if io.type(part.file) == 'file' then part.file:close() end
        assert.is_true(ok)
        assert.is_nil(result)
        assert.match(tostring(err), 'header write failed')
        assert.equal(after, before)
    end
end

function testcase.encode_pathname_writefile_errors_close_owned_handles()
    for _, mode in ipairs({ "return", "raise", "close_then_raise" }) do
        local captured
        local part = { filename = 'x.txt', pathname = pathname }
        local result, err = multipart.encode({ foo = { part } }, 'b', {
            write = function(_, s) return #s end,
            writefile = function(_, file)
                captured = file
                if mode == "close_then_raise" then file:close() end
                if mode ~= "return" then error("file write failed") end
                return nil, 'file write failed'
            end,
        })
        local state = io.type(captured)
        if state == 'file' then captured:close() end
        assert.is_nil(result)
        assert.match(tostring(err), 'file write failed')
        assert.equal(state, 'closed file')
    end
end

function testcase.encode_error_keeps_caller_file_open()
    local file = assert(io.tmpfile())
    local result, err = multipart.encode({ foo = {
        { filename = 'x.txt', file = file },
    } }, 'b', {
        write = function() return nil, 'write failed' end,
        writefile = function() error('must not be reached') end,
    })
    local state = io.type(file)
    file:close()
    assert.is_nil(result)
    assert.match(tostring(err), 'write failed')
    assert.equal(state, 'file')
end
