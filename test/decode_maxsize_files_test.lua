local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local multipart = require('form.multipart')
local prefixes = {}
local files = {}

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
    local file, _, pathname = assert(mkstemp('./decode_total_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    local prefix = pathname:gsub('^%./', '')
    prefixes[#prefixes + 1] = prefix
    return prefix
end

local function reader(input)
    local pos = 1
    return {
        read = function(_, n)
            local s = input:sub(pos, pos + n - 1)
            pos = pos + #s
            if #s > 0 then return s end
        end,
    }
end

local header = '--b\r\nContent-Disposition: form-data; name="upload"; filename="x"\r\n\r\n'
local input = header .. 'abc\r\n--b\r\n' ..
    'Content-Disposition: form-data; name="upload"; filename="y"\r\n\r\n' ..
    'def\r\n--b--\r\nepilogue'

function testcase.before_each()
    -- Verify immediate cleanup without help from finalizers.
    collectgarbage('stop')
end

function testcase.after_each()
    for _, file in ipairs(files) do
        if io.type(file) == 'file' then file:close() end
    end
    files = {}
    for _, prefix in ipairs(prefixes) do
        for _, pathname in ipairs(files_with_prefix(prefix)) do
            os.remove(pathname)
        end
    end
    prefixes = {}
    collectgarbage('restart')
end

function testcase.decode_total_and_file_limits_are_independent()
    for _, source in ipairs({ input, reader(input) }) do
        local form, err = multipart.decode(source, 'b', unused_prefix(), 3, 3, #input)
        assert.is_nil(err)
        for _, part in ipairs(form.upload) do files[#files + 1] = part.file end
        assert.equal(form.upload[1].file:read('*a'), 'abc')
        assert.equal(form.upload[2].file:read('*a'), 'def')
    end
    local prefix = unused_prefix()
    local form, err = multipart.decode(reader(input), 'b', prefix, 2, 3, #input)
    assert.is_nil(form)
    assert.not_nil(errlib.is(err, errno.EFBIG))
    assert.match(tostring(err), 'multipart body too large')
    assert.empty(files_with_prefix(prefix))
end

function testcase.decode_cleans_completed_and_incomplete_files_on_total_limit()
    -- Place the limit in the first payload, second payload, closing boundary
    -- and epilogue, exercising cleanup of both current and completed files.
    for _, maxsize in ipairs({ #header + 1, #input - 25, #input - 13, #input - 1 }) do
        local prefix = unused_prefix()
        local received = 0
        local saw_files = false
        local source = {
            read = function(_, n)
                if #files_with_prefix(prefix) > 0 then saw_files = true end
                local s = input:sub(received + 1, received + n)
                received = received + #s
                if #s > 0 then return s end
            end,
        }
        local form, err = multipart.decode(source, 'b', prefix, nil, 1, maxsize)
        assert.is_nil(form)
        assert.equal(errlib.typeof(err), multipart.EDECODE)
        assert.not_nil(errlib.is(err, errno.EFBIG))
        assert.match(tostring(err), 'maxsize')
        assert.is_true(saw_files)
        assert.equal(received, maxsize + 1)
        assert.empty(files_with_prefix(prefix))
    end
end

function testcase.decode_rejects_whole_string_before_creating_upload_files()
    local prefix = unused_prefix()
    local form, err = multipart.decode(input, 'b', prefix, nil, nil, #input - 1)
    assert.is_nil(form)
    assert.not_nil(errlib.is(err, errno.EFBIG))
    assert.match(tostring(err), 'maxsize')
    assert.empty(files_with_prefix(prefix))
end
