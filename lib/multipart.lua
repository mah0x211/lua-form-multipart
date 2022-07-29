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
local find = string.find
local format = string.format
local sub = string.sub
local match = string.match
local gmatch = string.gmatch
local lower = string.lower
local remove = os.remove
local pcall = pcall
local open = io.open
local isa = require('isa')
local is_string = isa.string
local is_file = isa.file
local is_uint = isa.uint
local is_table = isa.table
local is_func = isa.func
local mkstemp = require('mkstemp')
local gcfn = require('gcfn')

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
--- @return integer|nil nbyte
--- @return any err
local function encode_part_file(ctx, name, part)
    local writer = ctx.writer
    local chunksize = ctx.chunksize
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
    s, err = file:read(chunksize)
    while s do
        n, err = writer:write(s)
        if err then
            return nil, err
        end
        nbyte = nbyte + n
        s, err = file:read(chunksize)
    end

    if err then
        return nil, format('failed to read file %q in %q: %s', part.filename,
                           name, err)
    end

    return nbyte
end

--- encode_part_data
--- @param ctx table
--- @param name string
--- @param part table
--- @return integer|nil nbyte
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

    if not is_string(data) then
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
--- @return integer|nil nbyte
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
            if is_table(vals) then
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
--- @return integer|nil nbyte
--- @return any err
local function encode_form(ctx, form)
    local writer = ctx.writer
    local nbyte = 0

    for name, parts in pairs(form) do
        if is_string(name) and is_table(parts) then
            for _, part in ipairs(parts) do
                local t = type(part)
                local n, err

                if VALID_DATATYPE[t] then
                    n, err = encode_part(ctx, name, {
                        data = part,
                    }, encode_part_data)
                elseif t == 'table' then
                    if part.header ~= nil and not is_table(part.header) then
                        -- invalid header field
                        return nil,
                               format('header field in %q must be table', name)
                    elseif part.filename == nil then
                        if VALID_DATATYPE[type(part.data)] then
                            n, err = encode_part(ctx, name, part,
                                                 encode_part_data)
                        end
                    elseif not is_string(part.filename) then
                        -- invalid filename field
                        return nil, format(
                                   'filename field in %q must be string', name)
                    elseif part.file == nil then
                        -- open file
                        if part.pathname ~= nil then
                            if not is_string(part.pathname) then
                                -- invalid pathname field
                                return nil, format(
                                           'pathname field in %q must be string',
                                           name)
                            end

                            -- open target file
                            local tmpfile
                            tmpfile, err = open(part.pathname)
                            if not tmpfile then
                                return nil, format(
                                           'failed to open file %q for %q: %s',
                                           part.pathname, name, err)
                            end
                            part.file = tmpfile
                            ctx.tmpfile = tmpfile
                            n, err = encode_part(ctx, name, part,
                                                 encode_part_file)
                            ctx.tmpfile = nil
                            tmpfile:close()
                        end
                    elseif not is_file(part.file) then
                        -- invalid file field
                        return nil,
                               format('file field in %q must be file*', name)
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
    local n, err = writer:write(ctx.close_delimiter)
    if err then
        return nil, err
    end
    return nbyte + n
end

--- encode
--- @param writer table|userdata
--- @param form table
--- @param boundary string
--- @param chunksize integer
--- @return integer? nbyte
--- @return any err
local function encode(writer, form, boundary, chunksize)
    -- verify writer
    if not pcall(function()
        assert(is_func(writer.write))
    end) then
        error('writer.write must be function', 2)
    end

    -- verify form
    if not is_table(form) then
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
    if not is_string(boundary) then
        error('boundary must be string', 2)
    else
        local pos = find(boundary, '[^0-9a-zA-Z\'()+_,-./:=?]')
        if pos then
            -- non bcharsnospace character found
            error(format('invalid character %q in boundary',
                         sub(boundary, pos, pos)), 2)
        end
    end

    -- verify chunksize
    if chunksize == nil then
        chunksize = 4096
    elseif not is_uint(chunksize) or chunksize < 1 then
        error('chunksize must be uint greater than 0', 2)
    end

    local ctx = {
        writer = writer,
        delimiter = '--' .. boundary .. '\r\n',
        close_delimiter = '--' .. boundary .. '--',
        chunksize = chunksize,
    }

    local ok, res, err = pcall(encode_form, ctx, form)
    if ctx.tmpfile then
        ctx.tmpfile:close()
    end

    if not ok then
        return nil, res
    end

    return res, err
end

--- read_chunk
--- @param ctx table
--- @return string str
--- @return any err
local function read_chunk(ctx)
    -- read next chunk
    local str, err = ctx.reader:read(ctx.chunksize)
    if err then
        return nil, err
    elseif not str or #str == 0 then
        return nil, 'insufficient multipart/form-data'
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
            return false, 'multipart body too large'
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
--- @return boolean|nil again
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
            return false, 'multipart body too large'
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
--- @return table|nil part
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
                return nil, format('invalid header %q', line)
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
    local reader = ctx.reader
    local chunksize = ctx.chunksize

    ctx.buf = nil
    repeat
        local s, err = reader:read(chunksize)
        if err then
            return false, err
        end
    until not s

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
                return false, 'end of boundary found, but boundary not started'
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
--- @param reader table|userdata
--- @param boundary string
--- @param filetmpl string
--- @param maxsize integer
--- @param chunksize integer
--- @return table? form
--- @return any err
local function decode(reader, boundary, filetmpl, maxsize, chunksize)
    -- verify reader
    if not pcall(function()
        assert(is_func(reader.read))
    end) then
        error('reader.read must be function', 2)
    end

    -- verify boundary
    if not is_string(boundary) then
        error('boundary must be string', 2)
    end

    -- verify filetmpl
    if filetmpl == nil then
        filetmpl = '/tmp/lua_form_multipart_XXXXXX'
    elseif not is_string(filetmpl) then
        error('filetmpl must be string', 2)
    else
        filetmpl = filetmpl .. '_XXXXXX'
    end

    -- verify maxsize
    if maxsize ~= nil and not is_uint(maxsize) then
        error('maxsize must be uint', 2)
    end

    -- verify chunksize
    if chunksize == nil then
        chunksize = 4096
    elseif not is_uint(chunksize) or chunksize < 1 then
        error('chunksize must be uint greater than 0', 2)
    end

    local ctx = {
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
                return false, 'multipart body too large'
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
    if not ok or not res then
        discard_form(form)
        return nil, err or res
    end

    return form
end

return {
    encode = encode,
    decode = decode,
}
