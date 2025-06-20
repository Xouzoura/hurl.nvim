local log = require('hurl.vlog')
local git = require('hurl.git_utils')

local util = {}

--- Get the log file path
---@return string
util.get_log_file_path = function()
  return log.get_log_file()
end

--- Log info
---@vararg any
util.log_info = function(...)
  -- Only save log when debug is on
  if not _HURL_GLOBAL_CONFIG.debug then
    return
  end

  log.info(...)
end

--- Log error
---@vararg any
util.log_error = function(...)
  -- Only save log when debug is on
  if not _HURL_GLOBAL_CONFIG.debug then
    return
  end

  log.error(...)
end

--- Show info notification
---@vararg any
util.notify = function(...)
  --  Ignore if the flag is off
  if not _HURL_GLOBAL_CONFIG.show_notification then
    return
  end

  vim.notify(...)
end

--- Get visual selection
---@return string[]
util.get_visual_selection = function()
  local s_start = vim.fn.getpos("'<")
  local s_end = vim.fn.getpos("'>")
  local n_lines = math.abs(s_end[2] - s_start[2]) + 1
  local lines = vim.api.nvim_buf_get_lines(0, s_start[2] - 1, s_end[2], false)
  lines[1] = string.sub(lines[1], s_start[3], -1)
  if n_lines == 1 then
    lines[n_lines] = string.sub(lines[n_lines], 1, s_end[3] - s_start[3] + 1)
  else
    lines[n_lines] = string.sub(lines[n_lines], 1, s_end[3])
  end
  return lines
end

--- Create tmp file
---@param content any
---@return string|nil
util.create_tmp_file = function(content)
  -- create temp file base on pid and datetime
  local tmp_file = string.format(
    '%s/%s.hurl',
    vim.fn.stdpath('cache'),
    vim.fn.getpid() .. '-' .. vim.fn.localtime()
  )

  if not tmp_file then
    util.lor_error('hurl: failed to create tmp file')
    util.notify('hurl: failed to create tmp file', vim.log.levels.ERROR)
    return
  end

  local f = io.open(tmp_file, 'w')
  if not f then
    return
  end
  if type(content) == 'table' then
    local c = vim.fn.join(content, '\n')
    f:write(c)
  else
    f:write(content)
  end
  f:close()

  return tmp_file
end

--- Create custom command
---@param cmd string The command name
---@param func function The function to execute
---@param opt table The options
util.create_cmd = function(cmd, func, opt)
  opt = vim.tbl_extend('force', { desc = 'hurl.nvim ' .. cmd }, opt or {})
  vim.api.nvim_create_user_command(cmd, func, opt)
end

--- Format the body of the request
---@param body string
---@param type 'json' | 'html' | 'xml' | 'text'
---@return string[] | nil
util.format = function(body, type)
  local formatters = _HURL_GLOBAL_CONFIG.formatters
    or {
      json = { 'jq' },
      html = { 'prettier', '--parser', 'html' },
      xml = { 'tidy', '-xml', '-i', '-q' },
    }

  -- If no formatter is defined, return the body
  if not formatters[type] then
    return vim.split(body, '\n')
  end

  util.log_info('formatting body with ' .. type)
  local stdout = vim.fn.systemlist(formatters[type], body)
  if vim.v.shell_error ~= 0 then
    util.log_error('formatter failed' .. vim.v.shell_error)
    util.notify('formatter failed' .. vim.v.shell_error, vim.log.levels.ERROR)
    return vim.split(body, '\n')
  end

  if stdout == nil or #stdout == 0 then
    util.log_info('formatter returned empty body')
    return vim.split(body, '\n')
  end

  util.log_info('formatted body: ' .. table.concat(stdout, '\n'))
  return stdout
end
local function contains(table, value)
  for _, v in ipairs(table) do
    if v == value then
      return true
    end
  end
  return false
end
--- Render header table
---@param headers table
util.render_header_table = function(headers)
  local result = {}
  local maxKeyLength = 0
  for k, _ in pairs(headers) do
    maxKeyLength = math.max(maxKeyLength, #k)
  end
  local line = 0

  -- Add 'url' header first if it exists
  if headers['url'] then
    table.insert(result, string.format('%-' .. maxKeyLength .. 's | %s', 'url', headers['url']))
    line = line + 1
    headers['url'] = nil
  end
  if headers['params'] and type(headers['params']) == 'table' then
    table.insert(result, string.format('%-' .. maxKeyLength .. 's | %s', 'Params/Body', ''))
    line = line + 1

    for k, v in pairs(headers['params']) do
      local formatted_value = string.format('{"%s": "%s"}', k, v)
      table.insert(result, string.format('%-' .. maxKeyLength .. 's | %s', '', formatted_value))
      line = line + 1
    end
    headers['params'] = nil
  end
  for k, v in pairs(headers) do
    if contains(_HURL_GLOBAL_CONFIG.headers, k) then
      line = line + 1
      if line == 1 then
        -- Add header for the table view
        table.insert(
          result,
          string.format('%-' .. maxKeyLength .. 's | %s', 'Header Key', 'Header Value')
        )

        line = line + 1
      end
      table.insert(result, string.format('%-' .. maxKeyLength .. 's | %s', k, v))
    end
  end

  return {
    line = line,
    headers = result,
  }
end

--- Check if the response is json
---@param content_type string
---@return boolean
util.is_json_response = function(content_type)
  return string.find(content_type, 'json') ~= nil
end

util.is_html_response = function(content_type)
  return string.find(content_type, 'text/html') ~= nil
end

util.is_xml_response = function(content_type)
  return string.find(content_type, 'text/xml') ~= nil
    or string.find(content_type, 'application/xml') ~= nil
end

--- Check if nvim is running in nightly or stable version
---@return boolean
util.is_nightly = function()
  local is_stable_version = false
  if vim.fn.has('nvim-0.11.0') == 1 then
    is_stable_version = true
  end

  return is_stable_version
end

--- Check if a treesitter parser is available
---@param ft string
---@return boolean
local function treesitter_parser_available(ft)
  local res, parser = pcall(vim.treesitter.get_parser, 0, ft)
  return res and parser ~= nil
end

util.is_hurl_parser_available = treesitter_parser_available('hurl')

-- Looking for vars.env file base on the current file buffer
---@return table
local function find_env_files(file, root_dir, cache_dir, current_file_dir, scan_dir)
  local files = {
    {
      path = root_dir .. '/' .. file,
      dest = cache_dir .. '/' .. file,
    },
  }

  -- Scan git root directory and all sub directories with the current file buffer
  if git.is_git_repo() then
    local git_root = git.get_git_root()

    table.insert(files, {
      path = git_root .. '/' .. file,
      dest = cache_dir .. '/' .. file,
    })

    local git_root_parts = git.split_path(git_root)
    local current_dir_parts = git.split_path(current_file_dir)
    local sub_path = git_root

    for i = #git_root_parts + 1, #current_dir_parts do
      sub_path = sub_path .. '/' .. current_dir_parts[i]

      table.insert(files, {
        path = sub_path .. '/' .. file,
        dest = cache_dir .. '/' .. file,
      })
    end
  end

  for _, s in ipairs(scan_dir) do
    local dir = root_dir .. s.dir
    if vim.fn.isdirectory(dir) == 1 then
      table.insert(files, {
        path = dir .. '/' .. file,
        dest = cache_dir .. '/' .. file,
      })
    end
  end

  -- sort by path length, the current buffer file path will be the first
  table.sort(files, function(a, b)
    return #a.path > #b.path
  end)
  return files
end

-- Looking for vars.env file base on the current file buffer
---@return table
util.find_env_files_in_folders = function()
  local root_dir = vim.fn.expand('%:p:h')
  local cache_dir = vim.fn.stdpath('cache')
  local current_file_dir = vim.fn.expand('%:p:h:h')
  local env_files = {}

  local scan_dir = {
    {
      dir = '/src',
    },
    {
      dir = '/test',
    },
    {
      dir = '/tests',
    },
    {
      dir = '/server',
    },
    {
      dir = '/src/tests',
    },
    {
      dir = '/server/tests',
    },
  }

  for _, file in ipairs(_HURL_GLOBAL_CONFIG.env_file) do
    local env_file = find_env_files(file, root_dir, cache_dir, current_file_dir, scan_dir)
    vim.list_extend(env_files, env_file)
  end

  return env_files
end
util.has_file_in_opts = function(opts)
  if #opts == 0 then
    util.log_error('No file path provided in opts.')
    return false
  end

  local file_path = opts[1]

  local file = io.open(file_path, 'r')
  if not file then
    util.log_error('Error: Failed to open file: ' .. file_path)
    vim.notify('Error: Failed to open file: ' .. file_path, vim.log.levels.ERROR)
    return false
  end

  for line in file:lines() do
    if line:lower():find('file') or line:lower():find('multipart') then
      file:close() -- Close the file before returning
      return true -- Return true if any line contains the keyword
    end
  end

  file:close()

  return false
end
-- Function to extract the URL (and params) from the .hurl file
util.get_url_from_hurl_file = function(file_path)
  local url = nil
  local params = {}
  local in_params_section = false
  local file = io.open(file_path, 'r')

  if file then
    for line in file:lines() do
      -- Trim whitespace
      line = line:gsub('^%s*(.-)%s*$', '%1')
      line = line:gsub('%s+', ' ')

      -- Skip empty lines and comments
      if line ~= '' and not line:match('^#') then
        -- Check for HTTP methods
        local method_match = string.find(line, 'GET ')
          or string.find(line, 'POST ')
          or string.find(line, 'PUT ')
          or string.find(line, 'DELETE ')
          or string.find(line, 'PATCH ')

        if method_match then
          url = line
          in_params_section = false
        -- Check for parameter sections
        elseif line == '[QueryStringParams]' or line == '[FormParams]' then
          in_params_section = true
        elseif line:match('^{%s*$') then
          -- Start of JSON body
          in_params_section = true
          params['_body'] = ''
        -- Collect parameters if we're in a parameter section
        elseif in_params_section then
          if params['_body'] ~= nil then
            -- Collecting JSON body
            params['_body'] = params['_body'] .. line
          else
            -- Collecting form parameters
            local param_key, param_value = line:match('([^:]+):%s*(.+)')
            if param_key and param_value then
              params[param_key] = param_value
            end
          end
        end
      end
    end
    file:close()
  else
    util.log_info('Could not open file: ' .. file_path)
  end
  return url, params
end

util.convert_url_to_proper_format = function(opts, url)
  -- Assuming `url` is defined earlier in the code
  if url and url:find('{{') then -- Check if url contains '{{'
    local env_file

    -- Find the environment file in the opts that ends with .env
    for _, opt in ipairs(opts) do
      if opt:match('%.env$') then -- Check if the option ends with .env
        env_file = opt
        break -- Exit the loop once the first .env file is found
      end
    end
    if env_file then
      -- Read the environment file and get the variables
      local env_vars = {}
      local file = io.open(env_file, 'r')

      if not file then
        util.log_error('Could not open environment file: ' .. env_file)
      else
        -- Read each line of the file
        for line in file:lines() do
          -- Skip empty lines and comments
          line = line:match('^%s*(.-)%s*$') -- Trim whitespace
          if line ~= '' and not line:match('^#') then
            local key, value = line:match('^(%S+)%s*=%s*(.+)$') -- Match key=value
            if key and value then
              -- Trim quotes from value, if present
              value = value:gsub('^"%s*', ''):gsub('"%s*$', ''):gsub("^'%s*", ''):gsub("'%s*$", '')
              env_vars[key] = value
            end
          end
        end
        file:close()
      end

      for key, value in pairs(env_vars) do
        if url:find('{{' .. key .. '}}') then
          url = url:gsub('{{' .. key .. '}}', value)
        end
      end
    else
      util.log_error('No environment file found in opts.')
    end
    -- Load environment variables from the found env_file
  end

  return url
end
return util
