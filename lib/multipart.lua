--
-- Copyright (C) 2022 Masatoshi Fukunaga
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local tostring = tostring
local type = type
local find = string.find
local format = string.format
local sub = string.sub
local match = string.match
local gmatch = string.gmatch
local lower = string.lower
local concat = table.concat
local remove = os.remove
local open = io.open
local is = require('lauxhlib.is')
local is_file = is.file
local is_uint = is.uint
local is_pint = is.pint
local mkstemp = require('mkstemp')
local gcfn = require('gcfn')
local toerror = require('error').toerror
local new_error_type = require('error').type.new
-- constants
local EENCODE = new_error_type('form.multipart.encode', nil,
                               'form-multipart encode error')
local EDECODE = new_error_type('form.multipart.decode', nil,
                               'form-multipart decode error')

--
-- 3.3.  LEXICAL TOKENS
-- https://www.rfc-editor.org/rfc/rfc822#section-3.3
--
-- ALPHA       =  <any ASCII alphabetic character>
--                                             ; (101-132, 65.- 90.)
--                                             ; (141-172, 97.-122.)
-- DIGIT       =  <any ASCII decimal digit>    ; ( 60- 71, 48.- 57.)
-- CR          =  <ASCII CR, carriage return>  ; (     15,      13.)
-- LF          =  <ASCII LF, linefeed>         ; (     12,      10.)
-- SPACE       =  <ASCII SP, space>            ; (     40,      32.)
-- HTAB        =  <ASCII HT, horizontal-tab>   ; (     11,       9.)
-- LWSP-char   =  SPACE / HTAB                 ; semantics = SPACE
--
--
--
-- 5.1.1.  Common Syntax
-- https://www.rfc-editor.org/rfc/rfc2046#section-5.1.1
--
-- boundary := 0*69<bchars> bcharsnospace
--
-- bchars := bcharsnospace / " "
--
-- bcharsnospace := DIGIT / ALPHA / "'" / "(" / ")" /
--                  "+" / "_" / "," / "-" / "." /
--                  "/" / ":" / "=" / "?"
--
-- Overall, the body of a "multipart" entity may be specified as follows:
--
-- multipart-body := [preamble CRLF]
--                   dash-boundary *LWSP-char CRLF
--                   body-part *encapsulation
--                   close-delimiter *LWSP-char
--                   [CRLF epilogue]
--
-- preamble := discard-text
--
-- discard-text := *(*text CRLF) *text
--                 ; May be ignored or discarded.
--
-- dash-boundary := "--" boundary
--                  ; boundary taken from the value of
--                  ; boundary parameter of the
--                  ; Content-Type field.
--
-- LWSP-char := SPACE / HTAB
--              ; Composers MUST NOT generate
--              ; non-zero length transport
--              ; padding, but receivers MUST
--              ; be able to handle padding
--              ; added by message transports.
--
-- body-part := *MIME-part-headers [CRLF *OCTET]
--              ; Lines in a body-part must not start
--              ; with the specified dash-boundary and
--              ; the delimiter must not appear anywhere
--              ; in the body part.  Note that the
--              ; semantics of a body-part differ from
--              ; the semantics of a message, as
--              ; described in the text.
--
-- OCTET := <any 0-255 octet value>
--
-- encapsulation := delimiter transport-padding
--                  CRLF body-part
-- delimiter     := CRLF dash-boundary
--
-- close-delimiter := delimiter "--"
--
-- epilogue := discard-text
--

--- encode_part_file
--- @param ctx table
--- @param name string
--- @param part table
--- @return integer? nbyte
--- @return any err
local function encode_part_file(ctx, name, part)
    local writer = ctx.writer
    local file = part.file
    local nbyte = 0

    -- write content-disposition header
    local s = format(
                  'Content-Disposition: form-data; name=%q; filename=%q\r\n\r\n',
                  name, part.filename)
    local n, err = writer:write(s)
    if err then
        return nil, err
    end
    nbyte = nbyte + n

    -- write file content
    -- if part.is_tmpfile is true, the writer:writefile method must close the
    -- file argument
    part.name = name
    n = assert(file:seek('end'))
    n, err = writer:writefile(file, n, 0, part)
    if err then
        return nil, err
    end
    return nbyte + n
end

--- encode_part_data
--- @param ctx table
--- @param name string
--- @param part table
--- @return integer? nbyte
--- @return any err
local function encode_part_data(ctx, name, part)
    local writer = ctx.writer
    local data = part.data
    local nbyte = 0

    -- write content-disposition header
    local s = format('Content-Disposition: form-data; name=%q\r\n\r\n', name)
    local n, err = writer:write(s)
    if err then
        return nil, err
    end
    nbyte = nbyte + n

    if type(data) ~= 'string' then
        data = tostring(data)
    end

    -- write data
    n, err = writer:write(data)
    if err then
        return nil, err
    end
    return nbyte + n
end

--- encode_part
--- @param ctx table
--- @param name string
--- @param part table
--- @param encode_body function
--- @return integer? nbyte
--- @return any err
local function encode_part(ctx, name, part, encode_body)
    local delimiter = ctx.delimiter
    local writer = ctx.writer
    local nbyte = 0

    -- write delimiter
    local n, err = writer:write(delimiter)
    if err then
        return nil, err
    end
    nbyte = nbyte + n

    -- verify headers
    if part.header then
        -- add headers
        for key, vals in pairs(part.header) do
            -- write only values with the valid key
            if type(vals) == 'table' and type(key) == 'string' and #key > 0 and
                not find(key, '%s') then
                for _, v in ipairs(vals) do
                    local s = format('%s: %s\r\n', key, tostring(v))
                    n, err = writer:write(s)
                    if err then
                        return nil, err
                    end
                    nbyte = nbyte + n
                end
            end
        end
    end

    -- write body-part
    n, err = encode_body(ctx, name, part)
    if not n then
        return nil, err
    end
    nbyte = nbyte + n

    -- write CRLF
    n, err = writer:write('\r\n')
    if err then
        return nil, err
    end
    return nbyte + n
end

local VALID_DATATYPE = {
    ['string'] = true,
    ['number'] = true,
    ['boolean'] = true,
}

--- encode_form
--- @param ctx table
--- @param form table
--- @return integer? nbyte
--- @return any err
local function encode_form(ctx, form)
    local nbyte = 0

    for name, parts in pairs(form) do
        if type(name) == 'string' and type(parts) == 'table' then
            for _, part in ipairs(parts) do
                local t = type(part)
                local n, err

                if VALID_DATATYPE[t] then
                    n, err = encode_part(ctx, name, {
                        data = part,
                    }, encode_part_data)
                elseif t == 'table' then
                    if part.header ~= nil and type(part.header) ~= 'table' then
                        -- invalid header field
                        return nil, EENCODE:new(
                                   format('header field in %q must be table',
                                          name))
                    elseif part.filename == nil then
                        if VALID_DATATYPE[type(part.data)] then
                            n, err = encode_part(ctx, name, part,
                                                 encode_part_data)
                        end
                    elseif type(part.filename) ~= 'string' then
                        -- invalid filename field
                        return nil, EENCODE:new(
                                   format('filename field in %q must be string',
                                          name))
                    elseif part.file == nil then
                        -- open file
                        if part.pathname ~= nil then
                            if type(part.pathname) ~= 'string' then
                                -- invalid pathname field
                                return nil, EENCODE(
                                           format(
                                               'pathname field in %q must be string',
                                               name))
                            end

                            -- open target file
                            local tmpfile
                            tmpfile, err = open(part.pathname)
                            if not tmpfile then
                                return nil, toerror(
                                           format(
                                               'failed to open file %q for %q: %s',
                                               part.pathname, name, err))
                            end
                            part.file = tmpfile
                            part.is_tmpfile = true
                            ctx.tmpfile = tmpfile
                            n, err = encode_part(ctx, name, part,
                                                 encode_part_file)
                            ctx.tmpfile = nil
                            part.is_tmpfile = nil
                        end
                    elseif not is_file(part.file) then
                        -- invalid file field
                        return nil, EENCODE(
                                   format('file field in %q must be file*', name))
                    else
                        n, err = encode_part(ctx, name, part, encode_part_file)
                    end
                end

                if err then
                    return nil, err
                elseif n then
                    nbyte = nbyte + n
                end
            end
        end
    end

    -- write close-delimiter
    local n, err = ctx.writer:write(ctx.close_delimiter)
    if err then
        return nil, err
    end
    return nbyte + n
end

--- is_valid_boundary
--- @param boundary string
--- @return boolean ok
--- @return any err
local function is_valid_boundary(boundary)
    --
    -- boundary := 0*69<bchars> bcharsnospace
    --
    -- bchars := bcharsnospace / " "
    --
    -- bcharsnospace := DIGIT / ALPHA / "'" / "(" / ")" /
    --                  "+" / "_" / "," / "-" / "." /
    --                  "/" / ":" / "=" / "?"
    --
    if type(boundary) ~= 'string' then
        error('boundary must be string', 2)
    end

    local pos = find(boundary, '[^0-9a-zA-Z\'()+_,-./:=?]')
    if pos then
        -- non bcharsnospace character found
        return false, format('invalid character %q found in boundary',
                             sub(boundary, pos, pos))

    end
    return true
end

--- @class form.multipart.writer
--- @field write fun(self, s:string):(n:integer?,err:any)
--- @field writefile fun(self, file:file*, len:integer, offset:integer, part:table):(n:integer?,err:any)

--- @class form.multipart.default_writer : form.multipart.writer
--- @field multipart? string[]
local DefaultWriter = {
    write = function(self, s)
        self.multipart[#self.multipart + 1] = s
        return #s, nil
    end,
    writefile = function(self, file, len, offset, part)
        -- write file content
        file:seek('set', offset)
        local s, err = file:read(len)
        if part.is_tmpfile then
            file:close()
        end

        if err then
            return nil, format('failed to read file %q in %q: %s',
                               part.filename, part.name, err)
        end
        return self:write(s)
    end,
}

--- reset_default_writer
--- @param writer form.multipart.writer
--- @return string[]? multipart
local function reset_default_writer(writer)
    if writer == DefaultWriter and DefaultWriter.multipart then
        local multipart = DefaultWriter.multipart
        DefaultWriter.multipart = nil
        return multipart
    end
end

--- encode
--- @param form table
--- @param boundary string
--- @param writer? form.multipart.writer
--- @return integer|string? res
--- @return any err
local function encode(form, boundary, writer)
    -- verify form
    if type(form) ~= 'table' then
        error('form must be table', 2)
    end

    -- verify boundary
    --
    -- boundary := 0*69<bchars> bcharsnospace
    --
    -- bchars := bcharsnospace / " "
    --
    -- bcharsnospace := DIGIT / ALPHA / "'" / "(" / ")" /
    --                  "+" / "_" / "," / "-" / "." /
    --                  "/" / ":" / "=" / "?"
    --
    local ok, err = is_valid_boundary(boundary)
    if not ok then
        error(err, 2)
    end

    -- verify writer
    if writer == nil then
        writer = DefaultWriter
        writer.multipart = {}
    elseif not pcall(function()
        assert(type(writer.write) == 'function')
        assert(type(writer.writefile) == 'function')
    end) then
        error('writer.write and writer.writefile must be functions', 2)
    end

    local ctx = {
        writer = writer,
        delimiter = '--' .. boundary .. '\r\n',
        close_delimiter = '--' .. boundary .. '--',
    }

    local res
    ok, res, err = pcall(encode_form, ctx, form)
    if ctx.tmpfile then
        ctx.tmpfile:close()
    end

    local multipart = reset_default_writer(writer)
    if not ok then
        return nil, toerror(res)
    elseif not res then
        return nil, toerror(err)
    elseif multipart then
        return concat(multipart, '')
    end
    return res
end

--- read_chunk
--- @param ctx table
--- @return string? str
--- @return any err
local function read_chunk(ctx)
    local str
    if ctx.reader then
        -- read next chunk
        local err
        str, err = ctx.reader:read(ctx.chunksize)
        if err then
            return nil, err
        end
    elseif ctx.chunk then
        -- consume chunk
        str, ctx.chunk = ctx.chunk, nil
    end

    if not str or #str == 0 then
        return nil, EDECODE:new('insufficient multipart/form-data')
    end
    return str
end

--- skip_terminator
--- @param ctx table
--- @return boolean ok
--- @return any err
local function skip_terminator(ctx)
    local buf = ctx.buf
    local maxsize = ctx.maxsize

    while true do
        -- skip *LWSP CR?LF
        local head, tail = find(buf, '[ \t]*\r?\n')
        if head then
            ctx.buf = sub(buf, tail + 1)
            return true
        end

        if maxsize and maxsize - #buf <= 0 then
            return false, EDECODE:new('multipart body too large')
        end

        -- read next chunk
        local chunk, err = read_chunk(ctx)
        if not chunk then
            return false, err
        end
        buf = buf .. chunk
    end
end

--- decode_body
--- @param ctx table
--- @param writer function
--- @return boolean ok
--- @return any err
--- @return boolean? again
local function decode_body(ctx, writer)
    local buf = ctx.buf
    local delimiter = ctx.delimiter
    local delimlen = #delimiter
    local close_delimiter = ctx.close_delimiter
    local close_delimlen = #close_delimiter
    local maxsize = ctx.maxsize
    local pos = 1

    while true do
        -- find: CR?LF<delimiter>
        local head, tail = find(buf, '\r?\n', pos)
        while head do
            -- remaining buf size must greater than: len(<close_delimiter>)
            if #buf - tail < close_delimlen then
                break
            end

            -- following string matches <delimiter>
            if sub(buf, tail + 1, tail + delimlen) == delimiter then
                -- use the data before the line-feeds as body data
                local ok, err = writer(sub(buf, 1, head - 1))
                if not ok then
                    return false, err
                end
                -- skip data and delimiter
                buf = sub(buf, tail + delimlen + 1)

                -- found close_delimiter
                if sub(buf, 1, 2) == '--' then
                    ctx.buf = sub(buf, 3)
                    return true
                end
                ctx.buf = buf

                -- skip *LWSP CR?LF
                ok, err = skip_terminator(ctx)
                if not ok then
                    return false, err
                end
                return true, nil, true
            end

            -- use the data including line-feeds as body data
            local ok, err = writer(sub(buf, 1, tail))
            if not ok then
                return false, err
            end

            buf = sub(buf, tail + 1)
            pos = 1
            head, tail = find(buf, '\r?\n')
        end

        if maxsize and maxsize - #buf <= 0 then
            return false, EDECODE:new('multipart body too large')
        end

        -- read next chunk
        local chunk, err = read_chunk(ctx)
        if not chunk then
            return false, err
        end
        buf = buf .. chunk
    end
end

--- decode_header
--- @param ctx any
--- @return table? part
--- @return any err
local function decode_header(ctx)
    local buf = ctx.buf
    local header = {}
    local part = {}
    local pos = 1

    while true do
        -- find line-feeds
        local head, tail = find(buf, '[ \t]*\r?\n', pos)
        while head do
            local line = sub(buf, 1, head - 1)

            -- end header lines
            if #line == 0 then
                ctx.buf = sub(buf, tail + 1)
                part.header = header
                if part['filename*'] then
                    part.filename = part['filename*']
                end
                return part
            end

            -- extract header
            local k, v = match(line, '([^: \t]+)%s*:%s*(.+)')
            if not k then
                return nil, EDECODE:new(format('invalid header %q', line))
            end

            k = lower(k)
            local vals = header[k]
            if not vals then
                vals = {}
                header[k] = vals
            end
            vals[#vals + 1] = v
            if k == 'content-disposition' then
                -- split name="value"
                for key, val in gmatch(v, '([^%s]+)="?([^"]+)"?') do
                    part[lower(key)] = val
                end
            end
            buf = sub(buf, tail + 1)
            pos = 1
            head, tail = find(buf, '\r?\n')
        end

        local len = #buf
        if len > 2 then
            pos = len - 1
        end

        -- read next chunk
        local chunk, err = read_chunk(ctx)
        if not chunk then
            return nil, err
        end
        buf = buf .. chunk
    end
end

--- discard epilogue
---@param ctx table
---@return boolean ok
---@return any err
local function discard_epilogue(ctx)
    ctx.buf = nil
    if not ctx.reader then
        ctx.chunk = nil
        return true
    end

    local reader = ctx.reader
    local chunksize = ctx.chunksize
    repeat
        local s, err = reader:read(chunksize)
        if err then
            return false, err
        end
    until not s or #s == 0

    return true
end

--- discard_preamble
--- @param ctx table
--- @return boolean ok
--- @return any err
local function discard_preamble(ctx)
    local buf = ctx.buf
    local delimiter = ctx.delimiter
    local close_delimiter = ctx.close_delimiter
    local pos = 1

    while true do
        -- find line-feeds
        local head, tail = find(buf, '[ \t]*\r?\n', pos)
        while head do
            local line = sub(buf, 1, head - 1)

            if line == delimiter then
                -- discard preamble data
                ctx.buf = sub(buf, tail + 1)
                return true
            elseif line == close_delimiter then
                return false, EDECODE:new(
                           'end of boundary found, but boundary not started')
            end

            buf = sub(buf, tail + 1)
            pos = 1
            head, tail = find(buf, '[ \t]*\r?\n')
        end

        local len = #buf
        if len > 2 then
            pos = len - 1
        end

        -- read next chunk
        local chunk, err = read_chunk(ctx)
        if not chunk then
            return false, err
        end
        buf = buf .. chunk
    end
end

--- discard_form
--- @param form table
local function discard_form(form)
    for _, parts in pairs(form) do
        for _, part in ipairs(parts) do
            if part.file then
                part.file:close()
                if part.pathname then
                    remove(part.pathname)
                end
            end
        end
    end
end

--- gc_discard_form_file
--- @param pathname string
local function gc_discard_form_file(pathname)
    remove(pathname)
end

--- decode
--- @param chunk string|table|userdata
--- @param boundary string
--- @param filetmpl string
--- @param maxsize integer
--- @param chunksize integer
--- @return table? form
--- @return any err
local function decode(chunk, boundary, filetmpl, maxsize, chunksize)
    local reader = chunk
    -- verify chunk
    if type(chunk) == 'string' then
        reader = nil
    elseif not pcall(function()
        assert(type(reader.read) == 'function')
    end) then
        error('chunk must be string or it must have read method', 2)
    elseif chunksize == nil then
        chunksize = 4096
    elseif not is_pint(chunksize) then
        error('chunksize must be positive integer', 2)
    end

    -- verify boundary
    if type(boundary) ~= 'string' then
        error('boundary must be string', 2)
    end

    -- verify filetmpl
    if filetmpl == nil then
        filetmpl = '/tmp/lua_form_multipart_XXXXXX'
    elseif type(filetmpl) ~= 'string' then
        error('filetmpl must be string', 2)
    else
        filetmpl = filetmpl .. '_XXXXXX'
    end

    -- verify maxsize
    if maxsize ~= nil and not is_uint(maxsize) then
        error('maxsize must be uint', 2)
    end

    local ctx = {
        chunk = chunk,
        reader = reader,
        delimiter = '--' .. boundary,
        close_delimiter = '--' .. boundary .. '--',
        maxsize = maxsize,
        chunksize = chunksize,
        buf = '',
    }

    local form = {}

    -- parse multipart/form-data
    local ok, res, err = pcall(function()
        local ok, err = discard_preamble(ctx)
        if not ok then
            return false, err
        end

        -- setup body writer
        local part_data, part_file, nwrite
        local writer = function(s)
            nwrite = nwrite + #s
            if maxsize and maxsize - nwrite < 0 then
                return false, EDECODE:new('multipart body too large')
            elseif part_data then
                part_data = part_data .. s
                return true
            end
            return part_file:write(s)
        end

        -- parse body-part
        repeat
            local part
            part, err = decode_header(ctx)
            if not part then
                return false, err
            elseif not part.name then
                return false, EDECODE:new(
                           'Content-Disposition header does not contain a name parameter')
            end

            local again
            nwrite = 0
            if part.filename then
                part.file, err, part.pathname = mkstemp(filetmpl)
                if not part.file then
                    return false, err
                end
                part.gc = gcfn(gc_discard_form_file, part.pathname)
                part_file = part.file
                ok, err, again = decode_body(ctx, writer)
                part_file:seek('set')
                part_file = nil
            else
                part_data = ''
                ok, err, again = decode_body(ctx, writer)
                part.data = part_data
                part_data = nil
            end

            if not ok then
                return false, err
            end

            -- push to part list
            local parts = form[part.name]
            if not parts then
                parts = {}
                form[part.name] = parts
            end
            parts[#parts + 1] = part

        until not again

        ok, err = discard_epilogue(ctx)
        if not ok then
            return false, err
        end
        return true
    end)

    -- failed to parse
    if not ok then
        discard_form(form)
        return nil, toerror(res)
    elseif not res then
        discard_form(form)
        return nil, toerror(err)
    end
    return form
end

return {
    is_valid_boundary = is_valid_boundary,
    encode = encode,
    decode = decode,
}
