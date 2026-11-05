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
local huge = math.huge
local find = string.find
local format = string.format
local gsub = string.gsub
local sub = string.sub
local match = string.match
local lower = string.lower
local concat = table.concat
local remove = os.remove
local open = io.open
local file_type = io.type
local is = require('lauxhlib.is')
local is_file = is.file
local is_uint = is.uint
local is_pint = is.pint
local mkstemp = require('mkstemp')
local gcfn = require('gcfn')
local errorf = require('error').format
local toerror = require('error').toerror
local new_errno = require('errno').new
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

--- Seek a file, retaining the numeric errno when positioning fails.
--- @param file file*
--- @param whence? string
--- @param offset? integer
--- @return integer position
local function seek_file(file, whence, offset)
    local position, err, errnum = file:seek(whence, offset)
    if not position then
        error(new_errno(errnum, err, 'seek'), 0)
    end
    return position
end

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
    local offset = seek_file(file)
    local len = seek_file(file, 'end') - offset
    if len < 0 then
        len = 0
    end
    seek_file(file, 'set', offset)
    n, err = writer:writefile(file, len, offset, part)
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

--- close_tmpfile
--- @param ctx table
local function close_tmpfile(ctx)
    if ctx.tmpfile then
        if file_type(ctx.tmpfile) == 'file' then
            ctx.tmpfile:close()
        end
        ctx.tmpfile = nil
    end
end

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
                        return nil, new_errno('EINVAL', format(
                                                  'header field in %q must be table',
                                                  name))
                    elseif part.filename == nil then
                        if VALID_DATATYPE[type(part.data)] then
                            n, err = encode_part(ctx, name, part,
                                                 encode_part_data)
                        end
                    elseif type(part.filename) ~= 'string' then
                        -- invalid filename field
                        return nil, new_errno('EINVAL', format(
                                                  'filename field in %q must be string',
                                                  name))
                    elseif part.file == nil then
                        -- open file
                        if part.pathname ~= nil then
                            if type(part.pathname) ~= 'string' then
                                -- invalid pathname field
                                return nil, new_errno('EINVAL', format(
                                                          'pathname field in %q must be string',
                                                          name))
                            end

                            -- open target file
                            local tmpfile, errnum
                            tmpfile, err, errnum = open(part.pathname)
                            if not tmpfile then
                                return nil,
                                       errorf(
                                           format(
                                               'failed to open file %q for %q',
                                               part.pathname, name),
                                           new_errno(errnum, err, 'open'))
                            end
                            ctx.tmpfile = tmpfile
                            -- Keep library-owned handles out of reusable input.
                            local file_part = {}
                            for key, value in pairs(part) do
                                file_part[key] = value
                            end
                            file_part.header = part.header
                            file_part.filename = part.filename
                            file_part.pathname = part.pathname
                            file_part.file = tmpfile
                            file_part.is_tmpfile = true
                            n, err = encode_part(ctx, name, file_part,
                                                 encode_part_file)
                            close_tmpfile(ctx)
                        end
                    elseif not is_file(part.file) then
                        -- invalid file field
                        return nil, new_errno('EINVAL', format(
                                                  'file field in %q must be file*',
                                                  name))
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
--- @return string? err
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

    if #boundary < 1 or #boundary > 70 then
        return false, 'boundary length must be between 1 and 70 bytes'
    elseif sub(boundary, -1) == ' ' then
        return false, 'boundary must not end with a space'
    end

    local pos = find(boundary, '[^0-9a-zA-Z \'()+_,-./:=?]')
    if pos then
        -- A character outside bchars was found.
        return false, format('invalid character %q found in boundary',
                             sub(boundary, pos, pos))

    end
    return true
end

--- @class form.multipart.writer
--- @field write fun(self, s:string):(n:integer?,err:any)
--- @field writefile fun(self, file:file*, len:integer, offset:integer, part:table):(n:integer?,err:any)

--- @class form.multipart.default_writer : form.multipart.writer
--- @field multipart string[]

--- default_write
--- @param self form.multipart.default_writer
--- @param s string
--- @return integer n
local function default_write(self, s)
    self.multipart[#self.multipart + 1] = s
    return #s, nil
end

--- default_writefile
--- @param self form.multipart.default_writer
--- @param file file*
--- @param len integer
--- @param _ integer
--- @param part table
--- @return integer? n
--- @return any err
local function default_writefile(self, file, len, _, part)
    local s = ''
    local err, errnum
    if len > 0 then
        s, err, errnum = file:read(len)
    end
    if part.is_tmpfile then
        file:close()
    end

    if err then
        return nil,
               errorf(
                   format('failed to read file %q in %q', part.filename,
                          part.name), new_errno(errnum, err, 'read'))
    end
    return self:write(s)
end

--- encode
--- @param form table
--- @param boundary string
--- @param writer? form.multipart.writer
--- @return string|integer|nil res
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
    local multipart
    if writer == nil then
        multipart = {}
        writer = {
            write = default_write,
            writefile = default_writefile,
            multipart = multipart,
        }
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
    close_tmpfile(ctx)

    if not ok then
        return nil, EENCODE:new(nil, toerror(res))
    elseif not res then
        return nil, EENCODE:new(nil, toerror(err))
    elseif multipart then
        return concat(multipart, '')
    end
    return res
end

--- read_chunk
--- @param ctx table
--- @param allow_eof? boolean
--- @return string? str
--- @return any err
local function read_chunk(ctx, allow_eof)
    local str
    if ctx.reader then
        -- read next chunk
        -- Read at most one byte beyond the remaining budget to distinguish
        -- an exact-size stream ending at EOF from an oversized stream.
        local chunksize = ctx.chunksize
        local remaining = ctx.maxsize - ctx.nread
        if remaining < chunksize then
            chunksize = remaining + 1
        end
        local err
        str, err = ctx.reader:read(chunksize)
        if err then
            return nil, err
        end
    elseif ctx.chunk then
        -- consume chunk
        str, ctx.chunk = ctx.chunk, nil
    end

    if not str or #str == 0 then
        if allow_eof then
            return nil
        end
        return nil, new_errno('EINVAL', 'insufficient multipart/form-data')
    end

    -- Account for each received byte once, including bytes discarded later.
    ctx.nread = ctx.nread + #str
    if ctx.nread > ctx.maxsize then
        return nil, new_errno('EFBIG', 'multipart body exceeds maxsize')
    end
    return str
end

--- skip_terminator
--- @param ctx table
--- @param allow_eof? boolean Closing delimiters may end after padding at EOF.
--- @return boolean ok
--- @return any err
--- @return boolean? invalid True for invalid syntax; ctx.buf retains unconsumed data.
local function skip_terminator(ctx, allow_eof)
    local buf = ctx.buf

    -- Discard SP/HTAB transport padding (RFC 2046 section 5.1.1).
    while true do
        local _, tail = find(buf, '^[ \t]+')
        if tail then
            buf = sub(buf, tail + 1)
        end

        if #buf > 0 then
            -- Padding has ended.
            break
        end

        -- Need more data to determine whether padding continues.
        local chunk, err = read_chunk(ctx, allow_eof)
        if not chunk then
            if err then
                return false, err
            end
            -- EOF is final; epilogue discard must not read the source again.
            ctx.reader = nil
            ctx.chunk = nil
            ctx.buf = ''
            return true
        end
        buf = chunk
    end

    -- Padding has ended. A CR must be followed immediately by LF;
    -- keep accepting LF-only line endings for compatibility.
    local pos = 1
    local c = sub(buf, 1, 1)
    if c == '\r' then
        -- A CR must be followed by LF.
        if #buf == 1 then
            local chunk, err = read_chunk(ctx)
            if not chunk then
                return false, err
            end
            buf = buf .. chunk
        end
        pos = 2
        c = sub(buf, 2, 2)
    end

    -- A LF-only line ending is accepted for compatibility.
    if c ~= '\n' then
        ctx.buf = buf
        return false,
               new_errno('EINVAL', 'invalid multipart boundary terminator'),
               true
    end

    -- Discard the line ending.
    ctx.buf = sub(buf, pos + 1)
    return true
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
    local maxfilesize = ctx.maxfilesize or huge
    local nwrite = 0
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
                nwrite = nwrite + head - 1
                if nwrite > maxfilesize then
                    return false, new_errno('EFBIG', 'multipart body too large')
                end

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
                    ok, err = skip_terminator(ctx, true)
                    return ok, err
                end
                ctx.buf = buf

                -- skip *LWSP CR?LF
                ok, err = skip_terminator(ctx)
                if not ok then
                    return false, err
                end
                return true, nil, true
            end

            nwrite = nwrite + tail
            if nwrite > maxfilesize then
                return false, new_errno('EFBIG', 'multipart body too large')
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

        -- Retain a possible split CRLF + closing delimiter; write the
        -- preceding confirmed body bytes before reading another chunk.
        local nbody = #buf - close_delimlen - 1
        if nbody > 0 then
            nwrite = nwrite + nbody
            if nwrite > maxfilesize then
                return false, new_errno('EFBIG', 'multipart body too large')
            end

            local ok, err = writer(sub(buf, 1, nbody))
            if not ok then
                return false, err
            end
            buf = sub(buf, nbody + 1)
        end

        -- read next chunk
        local chunk, err = read_chunk(ctx)
        if not chunk then
            return false, err
        end
        buf = buf .. chunk
    end
end

-- RFC 2045 section 5.1: attribute = token; value = token / quoted-string.
-- MIME tokens exclude whitespace, controls, and tspecials.
local MIME_TOKEN = "[A-Za-z0-9!#$%%&'*+%.%^_`{|}~%-]+"
local DISPOSITION_PARAM_PATTERN = '^[ \t]*(' .. MIME_TOKEN .. ')[ \t]*=[ \t]*'
local MIME_TOKEN_PATTERN = '^' .. MIME_TOKEN
local LEADING_LWSP_PATTERN = '^[ \t]*'

--- Parse semicolon-separated attribute=value parameters from a
--- Content-Disposition header value, e.g. form-data; name="upload".
--- RFC 2183 section 2 and RFC 2045 section 5.1 allow token or quoted-string
--- values; quoted-pair escapes follow RFC 822 sections 3.3 and 3.4.1.
--- Returns an empty table without parameters; decode checks required name.
--- @param str string Content-Disposition header field value
--- @return table? params
--- @return any err
local function parse_disposition_params(str)
    local params = {}
    -- RFC 2183 section 2 permits zero parameters. RFC 7578 section 4.2
    -- requires name for form-data; that check belongs to decode().
    local pos = find(str, ';', 1, true)
    while pos do
        -- Parse the next attribute=value parameter.
        local head, tail, key = find(str, DISPOSITION_PARAM_PATTERN, pos + 1)
        if not head then
            return nil, new_errno('EINVAL',
                                  'invalid Content-Disposition parameters')
        end
        pos = tail + 1

        key = lower(key)
        if params[key] ~= nil then
            -- Duplicate parameters are invalid.
            return nil, new_errno('EINVAL',
                                  'invalid Content-Disposition parameters')
        end

        if sub(str, pos, pos) == '"' then
            -- Parse a quoted-string value.
            pos = pos + 1
            local chunks = {}

            -- RFC 822 section 3.3: qtext excludes quote, backslash
            -- and CR; a quoted-pair may escape any ASCII character.
            head = find(str, '["\\\r]', pos)
            while head do
                local c = sub(str, head, head)
                if c == '\r' then
                    return nil, new_errno('EINVAL',
                                          'invalid Content-Disposition parameters')
                end
                -- Append the text before the closing quote or quoted-pair.
                chunks[#chunks + 1] = sub(str, pos, head - 1)

                if c == '"' then
                    -- End of the quoted-string; omit the closing quote.
                    pos = head + 1
                    break
                elseif head == #str then
                    -- A trailing backslash has no character to escape.
                    return nil, new_errno('EINVAL',
                                          'invalid Content-Disposition parameters')
                end

                -- Decode the quoted-pair: omit the backslash and keep the
                -- following character verbatim, without interpreting it again.
                chunks[#chunks + 1] = sub(str, head + 1, head + 1)
                pos = head + 2
                head = find(str, '["\\\r]', pos)
            end

            -- No closing quote was found.
            if not head then
                return nil, new_errno('EINVAL',
                                      'invalid Content-Disposition parameters')
            end

            params[key] = concat(chunks)
        else
            -- Parse a token value.
            head, tail = find(str, MIME_TOKEN_PATTERN, pos)
            if not head then
                return nil, new_errno('EINVAL',
                                      'invalid Content-Disposition parameters')
            end
            params[key] = sub(str, head, tail)
            pos = tail + 1
        end

        -- RFC 822 section 3.4.2 allows SP/HTAB around symbols. Outside
        -- quoted strings, skip them before the next semicolon or end.
        local _, whitespace_end = find(str, LEADING_LWSP_PATTERN, pos)
        pos = whitespace_end + 1
        if pos > #str then
            break
        elseif sub(str, pos, pos) ~= ';' then
            return nil, new_errno('EINVAL',
                                  'invalid Content-Disposition parameters')
        end
    end
    return params
end

--- Consume a field while retaining its internal fold line endings.
--- @param ctx table
--- @return string? line Raw field without its final line ending; empty ends headers.
--- @return any err
local function consume_headerline(ctx)
    local buf = ctx.buf
    local pos = 1

    while true do
        -- Capture the position after LF so an empty separator does not
        -- consume SP/HTAB belonging to the first body line.
        local head, tail, afterlf = find(buf, '\r?\n()[ \t]*', pos)
        while head do
            if head == 1 then
                ctx.buf = sub(buf, afterlf)
                return ''
            end

            -- RFC 822 section 3.1.1: SP/HTAB after a line ending
            -- continues the same field. Keep that whitespace in the value.
            if afterlf <= tail then
                -- Continuation line detected; keep the whitespace in the value.
                pos = tail + 1
            elseif tail < #buf then
                -- No continuation line; this is the end of the header line.
                ctx.buf = sub(buf, tail + 1)
                return sub(buf, 1, head - 1)
            else
                -- LF at the chunk edge needs continuation lookahead.
                -- Keep the position at the start of the line.
                pos = head
                break
            end

            -- Continue searching for the next line ending.
            head, tail, afterlf = find(buf, '\r?\n()[ \t]*', pos)
        end

        -- If no line ending was found, set the position to the end of the buffer
        -- to read more data in the next iteration.
        if not head then
            pos = #buf
        end

        local chunk, err = read_chunk(ctx)
        if not chunk then
            return nil, err
        end
        buf = buf .. chunk
    end
end

--- decode_header
--- @param ctx table
--- @return table? part
--- @return any err
local function decode_header(ctx)
    local header = {}
    local params = {} ---@type table?

    while true do
        local line, err = consume_headerline(ctx)
        if not line then
            return nil, err
        elseif line == '' then
            return {
                header = header,
                params = params,
                name = params.name,
                filename = params.filename,
            }
        end

        -- RFC 5322 section 3.6.8: field names are printable ASCII
        -- excluding space/colon. Retain SP/HTAB before the colon
        -- as allowed by obs-optional (section 4.5.8).
        local k, v = match(line, '^([^: \t]+)[ \t]*:(.*)')
        -- [^!-~] matches bytes outside 0x21-0x7E. Use literal characters
        -- because Lua 5.1 does not support \xHH string escapes.
        if not k or find(k, '[^!-~]') then
            return nil, new_errno('EINVAL', format('invalid header %q', line))
        end
        k = lower(k)

        -- RFC 7578 section 4.8: ignore unsupported part headers,
        -- including fields with empty values.
        -- Unfold only values, leaving names subject to validation. Retain
        -- continuation whitespace; skip only leading SP/HTAB before values
        -- (RFC 822 sections 3.1.1 and 3.3).
        if k == 'content-disposition' then
            v = match(gsub(v, '\r?\n', ''), '^[ \t]*(.*)')
            if v == '' then
                return nil,
                       new_errno('EINVAL', format('invalid header %q', line))
            elseif header[k] then
                return nil, new_errno('EINVAL',
                                      'duplicate Content-Disposition header')
            end

            -- RFC 7578 section 4.2 requires form-data. Disposition
            -- types are case-insensitive (RFC 2183 section 2).
            local disposition = match(v, '^[^;]*')
            if not match(lower(disposition), '^form%-data[ \t]*$') then
                return nil, new_errno('EINVAL',
                                      'Content-Disposition type must be form-data')
            end

            params, err = parse_disposition_params(v)
            if not params then
                return nil, err
            end

            header[k] = {
                v,
            }
        elseif k == 'content-type' then
            v = match(gsub(v, '\r?\n', ''), '^[ \t]*(.*)')
            if v == '' then
                return nil,
                       new_errno('EINVAL', format('invalid header %q', line))
            end

            local vals = header[k]
            if not vals then
                vals = {}
                header[k] = vals
            end
            vals[#vals + 1] = v
        end
    end
end

--- discard epilogue
---@param ctx table
---@return boolean ok
---@return any err
local function discard_epilogue(ctx)
    ctx.buf = nil
    local s, err
    repeat
        s, err = read_chunk(ctx, true)
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
    local delimlen = #delimiter

    while true do
        -- Read the boundary plus two bytes for the optional closing "--".
        while #buf < delimlen + 2 do
            local chunk, err = read_chunk(ctx)
            if not chunk then
                return false, err
            end
            buf = buf .. chunk
        end

        if sub(buf, 1, delimlen) == delimiter then
            buf = sub(buf, delimlen + 1)
            local closing = sub(buf, 1, 2) == '--'
            if closing then
                buf = sub(buf, 3)
            end

            ctx.buf = buf
            local ok, err, invalid = skip_terminator(ctx)
            if ok then
                if closing then
                    return false, new_errno('EINVAL',
                                            'end of boundary found, but boundary not started')
                end
                return true
            elseif not invalid then
                return false, err
            end

            -- An invalid terminator belongs to preamble text. Keep any
            -- data read ahead so the next boundary is not lost.
            buf = ctx.buf
        end

        -- This line is not a boundary. Discard it through LF without
        -- retaining its fragments or matching again in the middle.
        while true do
            local head = find(buf, '\n', 1, true)
            if head then
                buf = sub(buf, head + 1)
                break
            end
            local err
            buf, err = read_chunk(ctx)
            if not buf then
                return false, err
            end
        end
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
--- @param maxfilesize? integer
--- @param chunksize integer
--- @param maxsize? integer Maximum received multipart body bytes.
--- @return table? form
--- @return any err
local function decode(chunk, boundary, filetmpl, maxfilesize, chunksize, maxsize)
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
    local valid, boundary_err = is_valid_boundary(boundary)
    if not valid then
        error(boundary_err, 2)
    end

    -- verify filetmpl
    if filetmpl == nil then
        filetmpl = '/tmp/lua_form_multipart_XXXXXX'
    elseif type(filetmpl) ~= 'string' then
        error('filetmpl must be string', 2)
    else
        filetmpl = filetmpl .. '_XXXXXX'
    end

    -- verify maxfilesize
    if maxfilesize ~= nil and not is_uint(maxfilesize) then
        error('maxfilesize must be uint', 2)
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
        chunksize = chunksize,
        maxsize = maxsize or huge,
        nread = 0,
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
        local part_data, part_file
        local writer = function(s)
            if part_data then
                part_data = part_data .. s
                return true
            end
            local result, write_err, errnum = part_file:write(s)
            -- Preserve the numeric errno returned by Lua for file-write errors.
            if not result and errnum then
                return nil, new_errno(errnum, write_err, 'write')
            end
            return result, write_err
        end

        -- parse body-part
        repeat
            local part
            part, err = decode_header(ctx)
            if not part then
                return false, err
            elseif not part.name then
                return false, new_errno('EINVAL',
                                        'Content-Disposition header does not contain a name parameter')
            end

            -- Register the part before reading its body so failed uploads
            -- are included in discard_form cleanup.
            local parts = form[part.name]
            if not parts then
                parts = {}
                form[part.name] = parts
            end
            parts[#parts + 1] = part

            local again
            if part.filename then
                ctx.maxfilesize = maxfilesize
                part.file, err, part.pathname = mkstemp(filetmpl)
                if not part.file then
                    return false, errorf(
                               'failed to create multipart temporary file', err)
                end
                part.gc = gcfn(gc_discard_form_file, part.pathname)
                part_file = part.file
                ok, err, again = decode_body(ctx, writer)
                part_file:seek('set')
                part_file = nil
            else
                ctx.maxfilesize = nil
                part_data = ''
                ok, err, again = decode_body(ctx, writer)
                part.data = part_data
                part_data = nil
            end

            if not ok then
                return false, err
            end
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
        return nil, EDECODE:new(nil, toerror(res))
    elseif not res then
        discard_form(form)
        return nil, EDECODE:new(nil, toerror(err))
    end
    return form
end

return {
    EENCODE = EENCODE,
    EDECODE = EDECODE,
    is_valid_boundary = is_valid_boundary,
    encode = encode,
    decode = decode,
}
