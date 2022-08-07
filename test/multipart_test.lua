require('luacov')
local testcase = require('testcase')
local mkstemp = require('mkstemp')
local multipart = require('form.multipart')

local PATHNAME_BAR

function testcase.before_all()
    local f, _
    f, _, PATHNAME_BAR = assert(mkstemp('./test_file_XXXXXX'))
    f:write('bar file')
    f:close()
end

function testcase.after_all()
    if PATHNAME_BAR then
        os.remove(PATHNAME_BAR)
    end
end

function testcase.is_valid_boundary()
    -- test that true
    assert(multipart.is_valid_boundary('foo-bar-baz'))

    -- test that return invalid character error
    local ok, err = multipart.is_valid_boundary('foo#bar-baz')
    assert.is_false(ok)
    assert.match(err, 'invalid character "#" found in boundary')

    -- test that throws an error if boundary is not string
    err = assert.throws(multipart.is_valid_boundary, {})
    assert.match(err, 'boundary must be string')
end

function testcase.encode()
    local file = assert(io.tmpfile())
    file:write('baz file')
    file:seek('set')

    local form = {
        foo = {
            'string value',
            {
                header = {
                    ['X-Example'] = {
                        'example header1',
                        'example header2',
                    },
                },
                filename = 'bar.txt',
                pathname = PATHNAME_BAR,
                data = 'if the filename is defined, this data will be ignored',
            },
            true,
            {
                header = {
                    ['this-header-is-ignored '] = {
                        'invalid key',
                    },
                },
                data = 'hello world',
            },
            {
                filename = 'baz.txt',
                file = file,
                pathname = PATHNAME_BAR, -- if the file is defined, pathname field will be ignored',
                data = 'if the filename is defined, data field will be ignored',
            },
        },
        qux = {
            123,
            {
                data = 'qux',
            },
            {
                -- empty data
            },
            false,
            {
                data = '',
            },
        },
    }

    -- test that encode a form table to string
    file:seek('set')
    local str = ''
    local n = assert(multipart.encode({
        write = function(_, s)
            str = str .. s
            return #s
        end,
        writefile = function(self, f, len, offset, part)
            -- write file content
            f:seek('set', offset)
            local s, err = f:read(len)
            if part.is_tmpfile then
                f:close()
            end

            if err then
                return nil, string.format('failed to read file %q in %q: %s',
                                          part.filename, part.name, err)
            end
            return self:write(s)
        end,
    }, form, 'test_boundary'))
    assert.equal(n, #str)
    for _, part in ipairs({
        table.concat({
            '--test_boundary',
            'Content-Disposition: form-data; name="foo"',
            '',
            'string value',
            '',
        }, '\r\n'),
        table.concat({
            '--test_boundary',
            'X-Example: example header1',
            'X-Example: example header2',
            'Content-Disposition: form-data; name="foo"; filename="bar.txt"',
            '',
            'bar file',
            '',
        }, '\r\n'),
        table.concat({
            '--test_boundary',
            'Content-Disposition: form-data; name="foo"',
            '',
            'true',
            '',
        }, '\r\n'),
        table.concat({
            '--test_boundary',
            'Content-Disposition: form-data; name="foo"',
            '',
            'hello world',
            '',
        }, '\r\n'),
        table.concat({
            '--test_boundary',
            'Content-Disposition: form-data; name="foo"; filename="baz.txt"',
            '',
            'baz file',
            '',
        }, '\r\n'),
        table.concat({
            '--test_boundary',
            'Content-Disposition: form-data; name="qux"',
            '',
            '123',
            '',
        }, '\r\n'),
        table.concat({
            '--test_boundary',
            'Content-Disposition: form-data; name="qux"',
            '',
            'qux',
            '',
        }, '\r\n'),
        table.concat({
            '--test_boundary',
            'Content-Disposition: form-data; name="qux"',
            '',
            'false',
            '',
        }, '\r\n'),
        table.concat({
            '--test_boundary',
            'Content-Disposition: form-data; name="qux"',
            '',
            '',
            '',
        }, '\r\n'),
        table.concat({
            '--test_boundary--',
        }, '\r\n'),
    }) do
        local head, tail = assert(string.find(str, part, nil, true))
        if head == 1 then
            str = string.sub(str, tail + 1)
        else
            str = string.sub(str, 1, head - 1) .. string.sub(str, tail + 1)
        end
    end
    assert.equal(#str, 0)

    -- test that throws an error if writer argument has no write function
    local err = assert.throws(multipart.encode, 'hello')
    assert.match(err, 'writer.write must be function')

    -- test that throws an error if form argument is invalid
    err = assert.throws(multipart.encode, {
        write = function()
        end,
        writefile = function()
        end,
    }, true)
    assert.match(err, 'form must be table')

    -- test that throws an error if boundary argument is invalid
    err = assert.throws(multipart.encode, {
        write = function()
        end,
        writefile = function()
        end,
    }, {}, true)
    assert.match(err, 'boundary must be string')
end

function testcase.decode()
    local str = table.concat({
        '--test_boundary',
        'X-Example: example header1',
        'X-Example: example header2',
        'Content-Disposition: form-data; name="foo"; filename="bar.txt"',
        '',
        'bar file',
        '--test_boundary',
        'Content-Disposition: form-data; name="foo"',
        '',
        'hello world',
        '--test_boundary',
        'Content-Disposition: form-data; name="foo"; filename="baz.txt"',
        '',
        'baz file',
        '--test_boundary',
        'Content-Disposition: form-data; name="qux"',
        '',
        'qux',
        '--test_boundary',
        'Content-Disposition: form-data; name="qux"',
        '',
        '',
        '--test_boundary--',
    }, '\r\n')

    -- test that decode a string to form table
    local form = assert(multipart.decode({
        read = function(_, n)
            if #str > 0 then
                local s = string.sub(str, 1, n)
                str = string.sub(str, n + 1)
                return s
            end
        end,
    }, 'test_boundary'))
    assert.contains(form.foo[1], {
        name = 'foo',
        header = {
            ['content-disposition'] = {
                'form-data; name="foo"; filename="bar.txt"',
            },
            ['x-example'] = {
                'example header1',
                'example header2',
            },
        },
        filename = 'bar.txt',
    })
    assert.equal(form.foo[1].file:read('*a'), 'bar file')
    assert.equal(form.foo[2], {
        name = 'foo',
        header = {
            ['content-disposition'] = {
                'form-data; name="foo"',
            },
        },
        data = 'hello world',
    })
    assert.contains(form.foo[3], {
        name = 'foo',
        header = {
            ['content-disposition'] = {
                'form-data; name="foo"; filename="baz.txt"',
            },
        },
        filename = 'baz.txt',
    })
    assert.equal(form.foo[3].file:read('*a'), 'baz file')
    assert.equal(form.qux, {
        {
            name = 'qux',
            header = {
                ['content-disposition'] = {
                    'form-data; name="qux"',
                },
            },
            data = 'qux',
        },
        {
            name = 'qux',
            header = {
                ['content-disposition'] = {
                    'form-data; name="qux"',
                },
            },
            data = '',
        },
    })

    -- test that throws an error if reader argument has no read function
    local err = assert.throws(multipart.decode, 'hello')
    assert.match(err, 'reader.read must be function')

    -- test that throws an error if boundary argument is invalid
    err = assert.throws(multipart.decode, {
        read = function()
        end,
    }, {})
    assert.match(err, 'boundary must be string')

    -- test that throws an error if filetmpl argument is invalid
    err = assert.throws(multipart.decode, {
        read = function()
        end,
    }, 'boundary', {})
    assert.match(err, 'filetmpl must be string')

    -- test that throws an error if maxsize argument is invalid
    err = assert.throws(multipart.decode, {
        read = function()
        end,
    }, 'boundary', '/tmp/test_file', {})
    assert.match(err, 'maxsize must be uint')

    -- test that throws an error if chunksize argument is invalid
    err = assert.throws(multipart.decode, {
        read = function()
        end,
    }, 'boundary', '/tmp/test_file', 0, 0)
    assert.match(err, 'chunksize must be uint greater than 0')
end

