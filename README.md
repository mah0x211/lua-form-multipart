# lua-form-multipart

[![test](https://github.com/mah0x211/lua-form-multipart/actions/workflows/test.yml/badge.svg)](https://github.com/mah0x211/lua-form-multipart/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/mah0x211/lua-form-multipart/branch/master/graph/badge.svg)](https://codecov.io/gh/mah0x211/lua-form-multipart)

encode/decode the multipart/form-data format.

***

## Installation

```
luarocks install form-multipart
```

## ok, err = multipart.is_valid_boundary( boundary )

Checks whether a boundary is valid. Returns `true` on success, or `false` and a
reason string on failure. A non-string argument raises an error.

A boundary must contain 1 to 70 bytes using ASCII letters, digits, spaces, or
`'()+_,-./:=?`, and must not end with a space. Both `encode` and `decode` reject
invalid boundary arguments before processing the form.

## Error Handling

`encode` and `decode` return `nil, err` on failure, using error objects from
[lua-error](https://github.com/mah0x211/lua-error). The outer error type is
`multipart.EENCODE` for encoding and `multipart.EDECODE` for decoding.
Original causes and available errno information are retained; string errors
without an errno remain untyped causes. Invalid top-level arguments raise exceptions.

Invalid part fields or malformed multipart data have an `errno.EINVAL` cause.
Exceeding `maxfilesize` or `maxsize` has an `errno.EFBIG` cause.
Use `error.typeof(err)` to check the outer type and `error.is(err, errno.EINVAL)`
or `error.is(err, errno.EFBIG)` to inspect causes.


## res, err = multipart.encode( form, boundary [, writer] )

encode a form table to string in `multipart/form-data` format.

**Parameters**

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
- `boundary:string`: a boundary string accepted by `multipart.is_valid_boundary`.
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
    - file:file*: file that contains the file data.
    - len:integer: number of bytes from the current file position to the end of the file.
    - offset:integer: file offset at which to begin the writeout.
    - part:table: a file data that contains the `filename` and `file` fields. if `part.is_tmpfile` is `true`, `file` must be closed by this method.
    ```

Files are encoded from their current position to the end of the file. Seek to
position zero before calling `encode` to include the whole file. Custom
writers receive that position as `offset` and the remaining length as `len`;
they must honor these arguments and position the file as needed. If no bytes
remain, the file part has an empty body.

The encoder closes files it opens from `pathname`. Caller-supplied file
handles remain the caller's responsibility.
For pathname parts, the input is left unchanged so the form can be reused.
For these parts, custom writers receive `part.file` and `part.is_tmpfile=true`.

**Returns**

- `res:string|integer|nil`: a string in `multipart/form-data` format, number of bytes written, or nil on error.
  - if the `writer` parameter is not specified, it returns a string in `multipart/form-data` format.
  - otherwise, it returns the number of bytes written to the `writer:write` and `writer:writefile` methods.
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
}, 'example_boundary', {
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
}))
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


## form, err = multipart.decode( chunk, boundary [, filetmpl [, maxfilesize [, chunksize [, maxsize]]]] )

decode a string in `multipart/form-data` format.

**Parameters**

- `chunk:string|table|userdata`: a string in `multipart/form-data` format.
    -  if the `chunk` parameter is not string, it must have the `chunk.read` method.
        ```
        s, err = chunk:read( n )
        - s:string: a string in multipart/form-data format.
        - err:any: error value.
        - n:integer: maximum number of bytes to read.
        ```
- `boundary:string`: a boundary string accepted by `multipart.is_valid_boundary`.
- `filetmpl:string`: template for the filename to be created. the filename will be appended with `_XXXXXX` at the end. the `_XXXXXXXX` will be a random string. (default: `/tmp/lua_form_multipart_XXXXXX`)
- `maxfilesize:integer`: maximum number of body bytes per file. Text fields and multipart boundaries or padding are not counted. Zero permits only empty files; nil leaves file sizes unlimited.
- `chunksize:integer`: if `chunk` is not a string, the maximum number of bytes requested from `chunk.read` per call. This value must be greater than `0`. Requests may be smaller when `maxsize` is set. (default: `4096`)
- `maxsize:integer`: maximum total bytes received, including the preamble, part headers, text and file data, boundaries, padding and epilogue. Must be a nonnegative integer; nil leaves the total unlimited. Exactly the limit is allowed. This limit is independent of `maxfilesize`.

**Returns**

- `form:table`: a form table
- `err:any`: error value.

Invalid suffixes after a normal or closing boundary delimiter return a decoding
error. SP/HTAB padding is accepted; normal delimiters require a line ending,
while closing delimiters may end at EOF.

Each part accepts only one Content-Disposition header. Repeated occurrences,
even with identical values, return a decoding error. Separate parts may use
the same `name`.

Content-Disposition parameters accept token or quoted-string values, including
empty quoted strings. Quoted-pair escapes are unescaped; `=` and `;` inside
quoted strings remain part of the value. Malformed parameters and repeated
parameter names (case-insensitive) return a decoding error. An unescaped CR
in a quoted value is invalid. Quoted non-ASCII bytes remain accepted.

Content-Disposition parameters are stored in `part.params`, including `name`
and `filename`. `part.name` and `part.filename` mirror `part.params.name` and
`part.params.filename`. The original header values remain in
`part.header['content-disposition']`.

`filename*` is retained in `part.params['filename*']` without decoding. It does
not determine `part.filename` or cause a part to be treated as a file when
`filename` is absent.

Other parameters are available through `part.params`, for example
`part.params.custom`.

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
--             params = {
--                 filename = "bar.txt",
--                 name = "foo"
--             },
--             pathname = "/tmp/lua_form_multipart_U6Fgvj"
--         },
--         [2] = {
--             data = "hello world",
--             header = {
--                 ["content-disposition"] = {
--                     [1] = "form-data; name=\"foo\""
--                 }
--             },
--             name = "foo",
--             params = {
--                 name = "foo"
--             }
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
--             name = "qux",
--             params = {
--                 name = "qux"
--             }
--         },
--         [2] = {
--             data = "",
--             header = {
--                 ["content-disposition"] = {
--                     [1] = "form-data; name=\"qux\""
--                 }
--             },
--             name = "qux",
--             params = {
--                 name = "qux"
--             }
--         }
--     }
-- }
```

