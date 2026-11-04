local testcase = require('testcase')
local assert = require('assert')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local rlimit = require('testcase.rlimit')
local signal = require('testcase.signal')
local multipart = require('form.multipart')
local errlib = require('error')
local errno = require('errno')
local original_limit
local ignoring_xfsz = false
local prefixes = {}

local function restore_environment()
    if original_limit then
        local restored = assert(rlimit('fsize', original_limit.cur))
        assert.equal(restored.cur, original_limit.cur)
        assert.equal(restored.max, original_limit.max)
        original_limit = nil
    end
    if ignoring_xfsz then
        assert(signal.sigdefault('SIGXFSZ'))
        ignoring_xfsz = false
    end
end

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

function testcase.after_each()
    restore_environment()
    for _, prefix in ipairs(prefixes) do
        for _, pathname in ipairs(files_with_prefix(prefix)) do
            os.remove(pathname)
        end
    end
    prefixes = {}
end

local function check_write_failure(payload, chunksize)
    local file, _, pathname = assert(mkstemp('./decode_write_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    local prefix = pathname:gsub('^%./', '')
    prefixes[#prefixes + 1] = prefix
    local input = '--b\r\nContent-Disposition: form-data; name="foo"; filename="x"' ..
        '\r\n\r\n' .. payload .. '\r\n--b--'

    original_limit = assert(rlimit('fsize'))
    -- Ignore SIGXFSZ so write returns EFBIG instead of terminating the runner.
    assert(signal.sigignore('SIGXFSZ'))
    ignoring_xfsz = true
    -- Change only the soft limit, which can be restored without privileges.
    assert(rlimit('fsize', 0))
    local source = input
    if chunksize then
        local pos = 1
        source = {
            read = function(_, n)
                local chunk = input:sub(pos, pos + n - 1)
                pos = pos + #chunk
                if #chunk > 0 then return chunk end
            end,
        }
    end
    local ok, form, err = pcall(multipart.decode, source, 'b', prefix, nil, chunksize)
    restore_environment()

    assert.is_true(ok)
    assert.is_nil(form)
    assert.match(tostring(err), 'File too large')
    assert.not_nil(multipart.EDECODE)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(errlib.is(err, errno.EFBIG))
    assert.equal(errlib.is(err, errno.EFBIG).op, 'write')
    assert.empty(files_with_prefix(prefix))
end

function testcase.decode_returns_write_error_before_boundary()
    -- Exceed stdio buffering so the actual write fails before close/flush.
    check_write_failure(string.rep('x', 65536))
end

function testcase.decode_returns_write_error_in_multiline_body()
    check_write_failure(string.rep('x', 65536) .. '\r\nnext line')
end

function testcase.decode_returns_write_error_while_streaming_newline_free_body()
    check_write_failure(string.rep('x', 65536), 4096)
end
