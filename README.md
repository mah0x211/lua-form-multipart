# lua-form-multipart

[![test](https://github.com/mah0x211/lua-form-multipart/actions/workflows/test.yml/badge.svg)](https://github.com/mah0x211/lua-form-multipart/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/mah0x211/lua-form-multipart/branch/master/graph/badge.svg)](https://codecov.io/gh/mah0x211/lua-form-multipart)

encode/decode the multipart/form-data format.

***

## Installation

```
luarocks install form-multipart
```

## Error Handling

the following functions return the `error` object created by https://github.com/mah0x211/lua-error module.


## n, err = multipart.encode( writer, form, boundary )

encode a form table to string in `multipart/form-data` format.

**Parameters**

- `writer:table|userdata`: call the `writer:write` and `writer:writefile` methods to output a string in `multipart/form-data` format.
    ```
    n, err = writer:write( s )
    - n:integer: number of bytes written.
    - err:any: error value.
    - s:string: output string.
    ```
    ```
    n, err = writer:writefile( file, len, offset, part )
    - n:integer: number of bytes written.
    - err:any: error value.
    - len:integer: file size.
    - offset:integer: file offset at which to begin the writeout.
    - part:table: a file data that contains the `filename` and `file` fields. if `part.is_tmpfile` is `true`, `file` must be closed by this method.
    ```
- `form:table`: a form table of the following format.
    ```
    {
        -- encode to body-part
        <name>:string = {
            <value>:string|boolean|number,
            -- table value
            {
                -- encode to MIME-part-headers
                header:table|nil = {
                    <name>:string = {
                        <value>:any, 
                        ...
                    }
                },
                data = <value>:string|nil
                -- if the filename field defined, add `filename="<filename>"` 
                -- value to the Content-Disposition header
                filename = <value>:string|nil,
                pathname = <value>:string|nil
                file = <value>:file*|nil
            },
            ...
        },
        ...
    }
    ```
- `boundary:string`: a boundary string.

**Returns**

- `n:integer`: total number of bytes written.
- `err:any`: error value.


**Usage**


```lua
local multipart = require('form.multipart')

-- encode a form table to multipart/form-data format string
local f = assert(io.tmpfile())
f:write('bar')
f:seek('set') -- the file position indicator must be set manually
local str = ''
local n = assert(multipart.encode({
    write = function(_, s)
        str = str .. s
        return #s
    end,
    writefile = function(self, f, len, offset, part)
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
}, {
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
            file = f,
            data = 'if filename field is defined, data field is ignored',
        },
        true,
        {
            data = 'hello world',
        },
    },
    qux = {
        {
            data = 'qux',
        },
        {
            -- if file or pathname field is not defined, this part is ignored
            filename = 'ignore',
        },
        123,
    },
}, 'example_boundary'))
assert(n == #str)
print(string.format(string.gsub(str, '[\r\n]', {
    ['\r'] = '\\r',
    ['\n'] = '\\n\n',
})))
--[[
--example_boundary\r\n
Content-Disposition: form-data; name="foo"\r\n
\r\n
string value\r\n
--example_boundary\r\n
X-Example: example header1\r\n
X-Example: example header2\r\n
Content-Disposition: form-data; name="foo"; filename="bar.txt"\r\n
\r\n
bar\r\n
--example_boundary\r\n
Content-Disposition: form-data; name="foo"\r\n
\r\n
true\r\n
--example_boundary\r\n
Content-Disposition: form-data; name="foo"\r\n
\r\n
hello world\r\n
--example_boundary\r\n
Content-Disposition: form-data; name="qux"\r\n
\r\n
qux\r\n
--example_boundary\r\n
Content-Disposition: form-data; name="qux"\r\n
\r\n
123\r\n
--example_boundary--
--]]
```


## form, err = multipart.decode( reader, boundary [, filetmpl [, maxsize [, chunksize]]] )

decode `multipart/form-data` format string.

**Parameters**

- `reader:table|userdata`: reads a string in `multipart/form-data` format with the `reader:read` method.
    ```
    s, err = reader:read( n )
    - n:integer: number of bytes read.
    - s:string: a string in multipart/form-data format.
    - err:any: error value.
    ```
- `boundary:string`: a boundary string.
- `filetmpl:string`: template for the filename to be created. the filename will be appended with `_XXXXXX` at the end. the `_XXXXXXXX` will be a random string. (default: `/tmp/lua_form_multipart_XXXXXX`)
- `maxsize:integer`: limit the maximum size per file.
- `chunksize:integer`: number of byte to read from the `reader.read` method. this value must be greater than `0`. (default: `4096`)

**Returns**

- `form:table`: a form table
- `err:any`: error value.

**Usage**

```lua
local dump = require('dump')
local multipart = require('form.multipart')

-- decode a multipart/form-data string to a form table
local str = table.concat({
    '--example_boundary',
    'Content-Disposition: form-data; name="qux"',
    '',
    'qux',
    '--example_boundary',
    'Content-Disposition: form-data; name="qux"',
    '',
    '',
    '--example_boundary',
    'Content-Disposition: form-data; name="foo"; filename="bar.txt"',
    '',
    'bar',
    '--example_boundary',
    'Content-Disposition: form-data; name="foo"',
    '',
    'hello world',
    '--example_boundary--',
    'MacBookPro-152:lua-form-multipart mah$ lua ./example.lua',
    '--example_boundary',
    'Content-Disposition: form-data; name="foo"; filename="bar.txt"',
    '',
    'bar',
    '--example_boundary',
    'Content-Disposition: form-data; name="foo"',
    '',
    'hello world',
    '--example_boundary',
    'Content-Disposition: form-data; name="qux"',
    '',
    'qux',
    '--example_boundary',
    'Content-Disposition: form-data; name="qux"',
    '',
    '',
    '--example_boundary--',
}, '\n')

local form = assert(multipart.decode({
    read = function(_, n)
        if #str > 0 then
            local s = string.sub(str, 1, n)
            str = string.sub(str, n + 1)
            return s
        end
    end,
}, 'example_boundary'))
print(dump(form))
-- {
--     foo = {
--         [1] = {
--             file = "file (0x7fff80b6b2f8)",
--             filename = "bar.txt",
--             gc = "gcfn: 0x7fcf8160c998",
--             header = {
--                 ["content-disposition"] = {
--                     [1] = "form-data; name=\"foo\"; filename=\"bar.txt\""
--                 }
--             },
--             name = "foo",
--             pathname = "/tmp/lua_form_multipart_U6Fgvj"
--         },
--         [2] = {
--             data = "hello world",
--             header = {
--                 ["content-disposition"] = {
--                     [1] = "form-data; name=\"foo\""
--                 }
--             },
--             name = "foo"
--         }
--     },
--     qux = {
--         [1] = {
--             data = "qux",
--             header = {
--                 ["content-disposition"] = {
--                     [1] = "form-data; name=\"qux\""
--                 }
--             },
--             name = "qux"
--         },
--         [2] = {
--             data = "",
--             header = {
--                 ["content-disposition"] = {
--                     [1] = "form-data; name=\"qux\""
--                 }
--             },
--             name = "qux"
--         }
--     }
-- }
```

