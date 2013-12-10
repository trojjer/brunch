'use strict'

debug = require('debug')('brunch:generate')
fs = require 'fs'
sysPath = require 'path'
waterfall = require 'async-waterfall'
anysort = require 'anysort'
common = require './common'
{SourceMapConsumer, SourceMapGenerator, SourceNode} = require 'source-map'

# Sorts by pattern.
#
# Examples
#
#   sort ['b.coffee', 'c.coffee', 'a.coffee'],
#     before: ['a.coffee'], after: ['b.coffee']
#   # => ['a.coffee', 'c.coffee', 'b.coffee']
#
# Returns new sorted array.
sortByConfig = (files, config) ->
  if toString.call(config) is '[object Object]'
    criteria = [
      config.before ? []
      config.after ? []
      config.bowerOrder ? []
      config.vendorConvention ? -> no
    ]
    anysort.grouped files, criteria, [0, 2, 3, 4, 1]
  else
    files

flatten = (array) ->
  array.reduce (acc, elem) ->
    acc.concat(if Array.isArray(elem) then flatten(elem) else [elem])
  , []

extractOrder = (files, config) ->
  types = files.map (file) -> file.type + 's'
  orders = Object.keys(config.files)
    .filter (key) ->
      key in types
    .map (key) ->
      config.files[key].order ? {}

  before = flatten orders.map (type) -> (type.before ? [])
  after = flatten orders.map (type) -> (type.after ? [])
  {conventions, bowerOrder} = config._normalized
  vendorConvention = conventions.vendor
  {before, after, vendorConvention, bowerOrder}

sort = (files, config) ->
  paths = files.map (file) -> file.path
  indexes = Object.create(null)
  files.forEach (file, index) -> indexes[file.path] = file
  order = extractOrder files, config
  sortByConfig(paths, order).map (path) ->
    indexes[path]

# New.
concat = (files, path, type, definition) ->
  # nodes = files.map toNode
  root = new SourceNode()
  debug "Concatenating #{files.map((_) -> _.path).join(', ')} to #{path}"
  files.forEach (file) ->
    root.add file.node
    root.add ';' if type is 'javascript'
    data = if file.node.isIdentity then file.data else file.source
    root.setSourceContent file.node.source, data

  root.prepend definition(path, root.sourceContents) if type is 'javascript'
  root.toStringWithSourceMap file: path

mapOptimizerChain = (optimizer) -> (params, next) ->
  {data, code, map, path} = params
  debug "Optimizing '#{path}' with '#{optimizer.constructor.name}'"

  optimizeFn = optimizer.optimize or optimizer.minify

  optimizerArgs = if optimizeFn.length is 2
    # New API: optimize({data, path, map}, callback)
    [params]
  else
    # Old API: optimize(data, path, callback)
    [data, path]

  optimizerArgs.push (error, optimized) ->
    return next error if error?
    if toString.call(optimized) is '[object Object]'
      optimizedCode = optimized.data
      optimizedMap = optimized.map
    else
      optimizedCode = optimized
    if optimizedMap?
      json = optimizedMap.toJSON()
      newMap = SourceMapGenerator.fromSourceMap new SourceMapConsumer optimizedMap
      newMap._sources.add path
      newMap._mappings.forEach (mapping) ->
        mapping.source = path
      newMap._sourcesContents ?= {}
      newMap._sourcesContents["$#{path}"] = ''  # data
      newMap.applySourceMap smConsumer
    else
      newMap = map
    next error, {data: optimizedCode, code: optimizedCode, map: newMap, path}

  optimizeFn.apply optimizer, optimizerArgs

optimize = (data, map, path, optimizers, isEnabled, callback) ->
  initial = {data, code: data, map, path}
  return callback null, initial unless isEnabled
  first = (next) -> next null, initial
  waterfall [first].concat(optimizers.map mapOptimizerChain), callback

generate = (path, sourceFiles, config, optimizers, callback) ->
  type = if sourceFiles.some((file) -> file.type in ['javascript', 'template'])
    'javascript'
  else
    'stylesheet'
  optimizers = optimizers.filter((optimizer) -> optimizer.type is type)

  sorted = sort sourceFiles, config

  {code, map} = concat sorted, path, type, config._normalized.modules.definition

  withMaps = (map and config.sourceMaps)
  mapPath = "#{path}.map"

  optimize code, map, path, optimizers, config.optimize, (error, data) ->
    return callback error if error?

    if withMaps
      base = sysPath.basename mapPath
      controlChar = if config.sourceMaps is 'old' then '@' else '#'
      data.code += if type is 'javascript'
        "\n//#{controlChar} sourceMappingURL=#{base}"
      else
        "\n/*#{controlChar} sourceMappingURL=#{base}*/"

    common.writeFile path, data.code, ->
      if withMaps
        common.writeFile mapPath, data.map.toString(), callback
      else
        callback()

generate.sortByConfig = sortByConfig

module.exports = generate
