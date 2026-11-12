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
local lower = string.lower
local format = string.format
local gsub = string.gsub
local concat = table.concat
local open = io.open
local file_type = io.type
local is_file = require('lauxhlib.is').file
local gcfn = require('gcfn')
local errorf = require('error').format
local toerror = require('error').toerror
local new_errno = require('errno').new
local new_error_type = require('error').type.new
local common = require('form.multipart.common')
local is_valid_boundary = common.is_valid_boundary
local check_timeout = common.check_timeout
local protected_call = common.protected_call
local IS_LUA51 = common.IS_LUA51

local EENCODE = new_error_type('form.multipart.encode', nil,
                               'form-multipart encode error')

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

--- Validate a write result, preserving the writer's error/timeout first.
--- @param n integer?
--- @param err any
--- @param timeout boolean?
--- @param expected integer
--- @param method string
--- @return any err
local function check_write_result(n, err, timeout, expected, method)
    check_timeout(timeout, method)
    if not n or err or timeout then
        return err
    elseif n ~= expected then
        return new_errno('EIO', method .. ' returned an unexpected byte count')
    end
end

--- encode_part_file
--- @param ctx table
--- @param name string
--- @param part table
--- @return integer? nbyte
--- @return any err
--- @return boolean? timeout
local function encode_part_file(ctx, name, part)
    local writer = ctx.writer
    local file = part.file
    local nbyte = 0

    -- write content-disposition header
    local s = format(
                  'Content-Disposition: form-data; name=%q; filename=%q\r\n\r\n',
                  name, part.filename)
    local n, err, timeout = writer:write(s)
    err = check_write_result(n, err, timeout, #s, 'writer.write')
    if not n or err or timeout then
        return nil, err, timeout
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
    n, err, timeout = writer:writefile(file, len, offset, part)
    err = check_write_result(n, err, timeout, len, 'writer.writefile')
    if not n or err or timeout then
        return nil, err, timeout
    end
    return nbyte + n
end

--- encode_part_data
--- @param ctx table
--- @param name string
--- @param part table
--- @return integer? nbyte
--- @return any err
--- @return boolean? timeout
local function encode_part_data(ctx, name, part)
    local writer = ctx.writer
    local data = part.data
    local nbyte = 0

    -- write content-disposition header
    local s = format('Content-Disposition: form-data; name=%q\r\n\r\n', name)
    local n, err, timeout = writer:write(s)
    err = check_write_result(n, err, timeout, #s, 'writer.write')
    if not n or err or timeout then
        return nil, err, timeout
    end
    nbyte = nbyte + n

    if type(data) ~= 'string' then
        data = tostring(data)
    end

    -- write data
    n, err, timeout = writer:write(data)
    err = check_write_result(n, err, timeout, #data, 'writer.write')
    if not n or err or timeout then
        return nil, err, timeout
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
--- @return boolean? timeout
local function encode_part(ctx, name, part, encode_body)
    local delimiter = ctx.delimiter
    local writer = ctx.writer
    local nbyte = 0

    -- write delimiter
    local n, err, timeout = writer:write(delimiter)
    err = check_write_result(n, err, timeout, #delimiter, 'writer.write')
    if not n or err or timeout then
        return nil, err, timeout
    end
    nbyte = nbyte + n

    -- verify headers
    if part.header then
        -- add headers
        for key, vals in pairs(part.header) do
            -- Content-Disposition is generated from the field name and filename.
            if type(vals) == 'table' and type(key) == 'string' and #key > 0 and
                not find(key, '%s') and lower(key) ~= 'content-disposition' then
                for _, v in ipairs(vals) do
                    local value = tostring(v)
                    -- RFC 5322 section 2.2.3: only CRLF followed by SP/HTAB
                    -- may appear as a folded header line.
                    if find(gsub(value, '\r\n[ \t]', ''), '[\r\n]') then
                        return nil, new_errno('EINVAL', format(
                                                  'header %q contains an invalid line break',
                                                  key))
                    end
                    local s = format('%s: %s\r\n', key, value)
                    n, err, timeout = writer:write(s)
                    err =
                        check_write_result(n, err, timeout, #s, 'writer.write')
                    if not n or err or timeout then
                        return nil, err, timeout
                    end
                    nbyte = nbyte + n
                end
            end
        end
    end

    -- write body-part
    n, err, timeout = encode_body(ctx, name, part)
    if not n or err or timeout then
        return nil, err, timeout
    end
    nbyte = nbyte + n

    -- write CRLF
    n, err, timeout = writer:write('\r\n')
    err = check_write_result(n, err, timeout, 2, 'writer.write')
    if not n or err or timeout then
        return nil, err, timeout
    end
    return nbyte + n
end

local VALID_DATATYPE = {
    ['string'] = true,
    ['number'] = true,
    ['boolean'] = true,
}

--- close_tmpfile
--- @param filectx table
local function close_tmpfile(filectx)
    local file = filectx.file
    if file then
        if file_type(file) == 'file' then
            file:close()
        end
        filectx.file = nil
    end
end

--- encode_form
--- @param ctx table
--- @param form table
--- @return integer? nbyte
--- @return any err
--- @return boolean? timeout
local function encode_form(ctx, form)
    local nbyte = 0

    for name, parts in pairs(form) do
        if type(name) == 'string' and type(parts) == 'table' then
            for _, part in ipairs(parts) do
                local t = type(part)
                local n = 0
                local err, timeout

                if VALID_DATATYPE[t] then
                    n, err, timeout = encode_part(ctx, name, {
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
                            n, err, timeout =
                                encode_part(ctx, name, part, encode_part_data)
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
                            ctx.filectx.file = tmpfile
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
                            n, err, timeout =
                                encode_part(ctx, name, file_part,
                                            encode_part_file)
                            close_tmpfile(ctx.filectx)
                        end
                    elseif not is_file(part.file) then
                        -- invalid file field
                        return nil, new_errno('EINVAL', format(
                                                  'file field in %q must be file*',
                                                  name))
                    else
                        n, err, timeout =
                            encode_part(ctx, name, part, encode_part_file)
                    end
                end

                if not n or err or timeout then
                    return nil, err, timeout
                end
                nbyte = nbyte + n
            end
        end
    end

    -- write close-delimiter
    local n, err, timeout = ctx.writer:write(ctx.close_delimiter)
    err = check_write_result(n, err, timeout, #ctx.close_delimiter,
                             'writer.write')
    if not n or err or timeout then
        return nil, err, timeout
    end
    return nbyte + n
end

--- @class form.multipart.writer
--- @field write fun(self, s:string):(n:integer?,err:any,timeout:boolean?)
--- @field writefile fun(self, file:file*, len:integer, offset:integer, part:table):(n:integer?,err:any,timeout:boolean?)

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
--- @return boolean? timeout
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
        filectx = {},
        delimiter = '--' .. boundary .. '\r\n',
        close_delimiter = '--' .. boundary .. '--',
    }

    local gco
    if IS_LUA51 then
        -- Do not retain the writer or its coroutine through the GC callback.
        gco = gcfn(close_tmpfile, ctx.filectx)
    end

    local res, timeout
    ok, res, err, timeout = protected_call(encode_form, ctx, form)
    close_tmpfile(ctx.filectx)
    if gco then
        gco:disable()
    end

    if not ok then
        return nil, EENCODE:new(nil, toerror(res))
    elseif not res then
        if timeout and not err then
            return nil, nil, timeout
        end
        return nil, EENCODE:new(nil, toerror(err)), timeout
    elseif multipart then
        return concat(multipart, '')
    end
    return res
end

return {
    EENCODE = EENCODE,
    encode = encode,
}
