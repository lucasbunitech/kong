-- Copyright (C) Mashape, Inc.

local cassandra = require "cassandra"

local BaseDao = {}
BaseDao.__index = BaseDao

setmetatable(BaseDao, {
  __call = function (cls, ...)
    local self = setmetatable({}, cls)
    self:_init(...)
    return self
  end,
})

function BaseDao:_init(collection)
  self._collection = collection
  self._cache = {}
end

-- Utility function to execute queries
-- @param cmd The CQL command to execute
-- @param args The arguments of the command
-- @return the result of the operation
function BaseDao:query(cmd, args)
  -- Creates a new session
  local session = cassandra.new()

  -- Sets the timeout for the subsequent operations
  session:set_timeout(configuration.dao.properties.timeout)

  -- Connects to Cassandra
  local connected, err = session:connect(configuration.dao.properties.host, configuration.dao.properties.port)
  if not connected then
    ngx.log(ngx.ERR, "error: ", err)
    return
  end

  -- Sets the default keyspace
  local ok, err = session:set_keyspace(configuration.dao.properties.keyspace)
  if not ok then
    ngx.log(ngx.ERR, "error: ", err)
    return
  end

  local stmt = self._cache[cmd]
  if not stmt then
    local new_stmt, err = session:prepare(cmd)
    if err then
      ngx.log(ngx.ERR, "error: ", err)
    end
    self._cache[cmd] = new_stmt
    stmt = new_stmt
  end

  -- Executes the command
  local result, err = session:execute(stmt, args)
  if err then
    ngx.log(ngx.ERR, "error: ", err)
    return
  end

  -- Puts back the connection in the nginx pool
  local ok, err = session:set_keepalive(configuration.dao.properties.keepalive)
  if not ok then
    ngx.log(ngx.ERR, "error: ", err)
    return
  end

  return result
end

-- Utility function to create query fields and values from an entity, useful for save and update
-- @param entity The entity whose fields needs to be parsed
-- @return A list of fields, of values placeholders, and the actual values table
local function get_cmd_args(entity)
  local cmd_field_values = {}
  local cmd_fields = {}
  local cmd_values = {}
  for k, v in pairs(entity) do
    table.insert(cmd_fields, k)
    table.insert(cmd_values, "?")
    if type(v) == "table" then
      table.insert(cmd_field_values, cassandra.list(v))
    elseif k == "id" then
      table.insert(cmd_field_values, cassandra.uuid(v))
    elseif k == "created_at" then
      table.insert(cmd_field_values, cassandra.timestamp(v))
    else
      table.insert(cmd_field_values, v)
    end
  end

  return table.concat(cmd_fields, ","), table.concat(cmd_values, ","), cmd_field_values
end

function BaseDao:save(entity)
  -- Prepares the cmd arguments
  local cmd_fields, cmd_values, cmd_field_values = get_cmd_args(entity)

  -- Executes the command
  local cmd = "INSERT INTO " .. self._collection .. " (" .. cmd_fields .. ") VALUES (" .. cmd_values .. ")"
  self:query(cmd, cmd_field_values)

  return entity
end

function BaseModel:delete()
  local n_success, err = BaseModel:find_and_delete { id = self._t.id }
  return n_success, err
end

function BaseDao:update()
  local res, err = validate(self, self._t, self._SCHEMA, true)
  if not res then
    return nil, err
  else
    local data, err = dao[self._collection]:update(self._t)
    return data, err
  end
end

function BaseDao.find(args, page, size)
  local data, total, err = dao[self._collection]:find(args, page, size)
  return data, total, err
end

function BaseDao.find_and_delete(args)
  local n_success, err = dao[self._collection]:find_and_delete(args)
  return n_success, err
end

return BaseDao