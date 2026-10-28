local testcase = require('testcase')
local assert = require('assert')
local mkstemp = require('mkstemp')
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

function testcase.encode_pathname_form_is_reusable()
    local part = { filename = 'x.txt', pathname = pathname }
    local form = { foo = { part } }
    local first = assert(multipart.encode(form, 'b'))
    local second = assert(multipart.encode(form, 'b'))
    assert.equal(first, second)
    assert.equal(part, { filename = 'x.txt', pathname = pathname })
end

function testcase.encode_pathname_part_preserves_writer_metadata()
    local part = { filename = 'x.txt', pathname = pathname, marker = 'keep' }
    local captured
    local n = assert(multipart.encode({ foo = { part } }, 'b', {
        write = function(_, s) return #s end,
        writefile = function(_, file, len, offset, filepart)
            captured = file
            assert.equal(filepart.marker, 'keep')
            assert.equal(filepart.name, 'foo')
            assert.equal(filepart.file, file)
            assert.equal(filepart.is_tmpfile, true)
            assert(file:seek('set', offset))
            assert.equal(file:read(len), 'content')
            file:close()
            return len
        end,
    }))
    assert.equal(n > 0, true)
    assert.equal(io.type(captured), 'closed file')
    assert.is_nil(part.file)
    assert.is_nil(part.is_tmpfile)
    assert.is_nil(part.name)
end

function testcase.encode_pathname_fields_from_metatable()
    local part = setmetatable({}, {
        __index = {
            filename = "x.txt", pathname = pathname,
            header = { ["X-Example"] = { "value" } },
        },
    })
    local encoded = assert(multipart.encode({ foo = { part } }, "b"))
    assert.match(encoded, "filename=\"x.txt\"")
    assert.match(encoded, "X-Example: value")
    assert.match(encoded, "content")
    assert.is_nil(rawget(part, "file"))
    assert.is_nil(rawget(part, "is_tmpfile"))
end

function testcase.encode_pathname_form_is_reusable_after_writer_errors()
    for _, mode in ipairs({ 'return', 'raise' }) do
        local part = { filename = 'x.txt', pathname = pathname }
        local result, err = multipart.encode({ foo = { part } }, 'b', {
            write = function()
                if mode == 'raise' then error('write failed') end
                return nil, 'write failed'
            end,
            writefile = function() error('must not be reached') end,
        })
        assert.is_nil(result)
        assert.match(tostring(err), 'write failed')
        assert.equal(part, { filename = 'x.txt', pathname = pathname })
        local encoded = assert(multipart.encode({ foo = { part } }, 'b'))
        assert.match(encoded, 'content')
        assert.equal(part, { filename = 'x.txt', pathname = pathname })
    end
end

function testcase.encode_pathname_form_supports_nested_calls()
    local nested = false
    local inner
    local form
    local value = setmetatable({}, {
        __tostring = function()
            if not nested then
                nested = true
                inner = assert(multipart.encode(form, 'b'))
            end
            return 'header value'
        end,
    })
    local part = {
        filename = 'x.txt', pathname = pathname,
        header = { ['X-Example'] = { value } },
    }
    form = { foo = { part } }
    local encoded, err = multipart.encode(form, 'b')
    assert.is_nil(err)
    assert.equal(encoded, '--b\r\nX-Example: header value\r\n' ..
        'Content-Disposition: form-data; name="foo"; filename="x.txt"\r\n' ..
        '\r\ncontent\r\n--b--')
    assert.equal(inner, encoded)
    assert.is_nil(part.file)
    assert.is_nil(part.is_tmpfile)
    assert.is_nil(part.name)
end
