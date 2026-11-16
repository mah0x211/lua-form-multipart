local testcase = require('testcase')
local assert = require('assert')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local multipart = require('form.multipart')
local prefixes, files = {}, {}
local body = '--b\r\nContent-Disposition: form-data; name="upload"; filename="x"' ..
    '\r\n\r\npayload\r\n--b--'

local function paths(prefix)
    local found = {}
    assert.is_nil(readdir('.', function(name)
        if name:sub(1, #prefix + 1) == prefix .. '_' then
            found[#found + 1] = name
        end
    end))
    return found
end

local function unused_prefix()
    local file, _, pathname = assert(mkstemp('./decode_gc_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    local prefix = pathname:gsub('^%./', '')
    prefixes[#prefixes + 1] = prefix
    return prefix
end

function testcase.before_each()
    collectgarbage('stop')
end

function testcase.after_each()
    for _, file in ipairs(files) do
        if io.type(file) == 'file' then file:close() end
    end
    for _, prefix in ipairs(prefixes) do
        for _, pathname in ipairs(paths(prefix)) do os.remove(pathname) end
    end
    files, prefixes = {}, {}
    collectgarbage('restart')
end

function testcase.decode_failure_gc_preserves_replacement_after_explicit_cleanup()
    local prefix = unused_prefix()
    local pathname, captured
    local form, err = multipart.decode(body, 'b', {
        filetmpl = prefix,
        writer = { writefile = function(_, file)
            captured = file
            files[#files + 1] = file
            pathname = assert(paths(prefix)[1])
            return nil, 'write failed'
        end },
    })
    assert.is_nil(form)
    assert.match(tostring(err), 'write failed')
    assert.equal(io.type(captured), 'closed file')
    assert.empty(paths(prefix))

    local replacement = assert(io.open(pathname, 'wb'))
    assert(replacement:write('replacement'))
    assert(replacement:close())
    collectgarbage('collect')
    collectgarbage('collect')
    local remaining = assert(io.open(pathname, 'rb'))
    files[#files + 1] = remaining
    assert.equal(remaining:read('*a'), 'replacement')
end

function testcase.decode_failure_gc_preserves_replacement_when_file_already_removed()
    local prefix = unused_prefix()
    local pathname
    local form, err = multipart.decode(body, 'b', {
        filetmpl = prefix,
        writer = { writefile = function(_, file)
            files[#files + 1] = file
            pathname = assert(paths(prefix)[1])
            assert(os.remove(pathname))
            return nil, 'write failed'
        end },
    })
    assert.is_nil(form)
    assert.match(tostring(err), 'write failed')
    assert.empty(paths(prefix))

    local replacement = assert(io.open(pathname, 'wb'))
    assert(replacement:write('replacement'))
    assert(replacement:close())
    collectgarbage('collect')
    collectgarbage('collect')
    local remaining = assert(io.open(pathname, 'rb'))
    files[#files + 1] = remaining
    assert.equal(remaining:read('*a'), 'replacement')
end

function testcase.decode_success_keeps_gc_cleanup_for_returned_files()
    local prefix = unused_prefix()
    local pathname
    do
        local form = assert(multipart.decode(body, 'b', { filetmpl = prefix }))
        local part = form.upload[1]
        pathname = part.pathname
        files[#files + 1] = part.file
        assert.equal(part.file:read('*a'), 'payload')
    end
    collectgarbage('collect')
    collectgarbage('collect')
    assert.empty(paths(prefix))
    local missing = io.open(pathname, 'rb')
    assert.is_nil(missing)
end
