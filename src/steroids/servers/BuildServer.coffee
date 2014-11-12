Server = require "../Server"
Converter = require "../Converter"
util = require "util"
request = require "request"
semver = require "semver"
chalk = require "chalk"
winston = require "winston"
bodyParser = require "body-parser"
express = require "express"
tinylr = require "tiny-lr"

fs = require "fs"
Paths = require "../paths"

Updater = require "../Updater"

Project = require "../Project"
Deploy = require "../Deploy"
Data = require "../Data"

class ClientResolver

  constructor: (@request) ->

  ipInInterfaces: (ip, interfaces) =>
    for iface in interfaces
      return true if iface.ip == ip

    return false

  resolve: =>
    ios = @request.headers["user-agent"].match("iPhone|iPad|iPod")?
    android = ios == false

    interfaces = steroidsCli.server.interfaces()
    simulator = @ipInInterfaces(@request.ip, interfaces)

    clientVersion = @request.query["client_version"]

    clientVersionMatch = @request.headers["user-agent"].match(/AppGyverSteroids\/([^\s]+)/)
    clientVersion = clientVersionMatch[1] if clientVersionMatch

    if android
      androidVersionMatch = @request.headers["user-agent"].match(/Android (\d+\.\d+\.\d+)\;/)
      osVersion = androidVersionMatch[1] if androidVersionMatch

    if ios
      iosDeviceMatch = @request.headers["user-agent"].match(/(iPod|iPad|iPhone)/)
      device = iosDeviceMatch[0] || null
      iosOsVersionMatch = @request.headers["user-agent"].match(/OS ([^\s]*) like/)
      osVersion = iosOsVersionMatch[1] || null

    return {
      isIOS: ios
      isSimulator: simulator
      isAndroid: android
      version: clientVersion
      osVersion: osVersion
      device: device
    }

class BuildServer extends Server

  constructor: (@options) ->
    @server = @options.server
    @converter = new Converter Paths.application.configs.application
    @clients = {}

    if !fs.existsSync(Paths.application.logDir)
      fs.mkdir Paths.application.logDir

    winston.add winston.transports.File, {
      filename: Paths.application.logFile
      level: 'debug'
    }
    winston.remove winston.transports.Console

    super(@options)

    @tinylr = tinylr.middleware(app: @app, server: @server.server)

    @app.use express.static(Paths.connectStaticFiles)
    @app.use express.static(Paths.application.distDir)
    @app.use bodyParser.json()
    @app.use @tinylr.middleware

  triggerLiveReload: ->
    @tinylr.server.changed
      body:
        files: ["dolan.js"]

  setRoutes: =>

    helper = (method, path, f) =>
        @app[method] path, (req, res) =>
          res.header "Access-Control-Allow-Origin", "*"
          res.header "Access-Control-Allow-Headers", "Content-Type"

          f(req, res).catch (err) ->
            res.status(500).json {error: "Can not do anything lol"}


    @app.get "/", (req, res) =>
      res.redirect("/__appgyver/index.html")

    @app.get "/appgyver/api/applications/1.json", (req, res) =>

      config = @converter.configToAnkaFormat()

      zipObject =
        url: "#{req.protocol}://#{req.hostname}:#{@options.port}/appgyver/zips/project.zip"

      config.archives.push zipObject

      if steroidsCli.options.argv.livereload != false
        config.livereload_host = "#{req.hostname}:#{@options.port}"
        config.livereload_url = "ws://#{req.hostname}:#{@options.port}/livereload"

      res.json config

    @app.get "/appgyver/zips/project.zip", (req, res)->
      res.sendFile Paths.temporaryZip

    @app.get "/refresh_client_events?:timestamp", (req, res)=>
      res.header "Access-Control-Allow-Origin", "*"
      res.header('Content-Type', 'text/event-stream')
      res.header('Cache-Control', 'no-cache')
      res.header('Connection', 'keep-alive')

      timestamp = key for key,val of req.query

      id = setInterval ()->

        if fs.existsSync Paths.temporaryZip
          filestamp = fs.lstatSync(Paths.temporaryZip).mtime.getTime()
        else
          filestamp = 0

        if parseInt(filestamp,10) > parseInt(timestamp,10)
          res.write 'event: refresh\ndata: true\n\n'
        else
          res.write 'event: refresh\ndata: false\n\n'

      , 1000

      res.on "close", ()->
        clearInterval id

    # Used for heartbeat
    @app.get "/__appgyver/ping", (req, res) =>
      res.header "Access-Control-Allow-Origin", "*"
      res.header "Access-Control-Allow-Headers", "Content-Type"
      res.status(200).send "Pong!"

    helper "get", "/__appgyver/deploy", (req, res) ->
      Deploy = require "../Deploy"
      deploy = new Deploy
        sharePage: false

      deploy.run().then () ->
        res.json deploy.cloudConfig
      .catch Deploy.DeployError, (err) ->
        res.status(500).json {error: "Can not deploy project"}

    @app.get "/__appgyver/app_config", (req, res) =>
      res.header "Access-Control-Allow-Origin", "*"
      res.header "Access-Control-Allow-Headers", "Content-Type"

      if fs.existsSync Paths.application.configs.app
        appConfig = require Paths.application.configs.app
        res.status(200).json appConfig
      else
        res.status(204).send ''

    @app.get "/__appgyver/cloud_config", (req, res) =>
      res.header "Access-Control-Allow-Origin", "*"
      res.header "Access-Control-Allow-Headers", "Content-Type"

      if fs.existsSync Paths.application.configs.cloud
        cloudConfig = require Paths.application.configs.cloud
        res.json cloudConfig
      else
        error = "Could not find config/cloud.json. Please run $ steroids deploy."

        res.status(404).json {error: error}

    helper "get", "/__appgyver/data/config", (req, res) =>
      data = new Data
      data.getConfig().then (config)->
        res.json config

    helper "post", "/__appgyver/data/init", (req, res) =>
      data = new Data
      data.init().then ->
        res.status(200).send "Success!"

    helper "post", "/__appgyver/data/sync", (req, res) =>
      data = new Data
      data.sync().then ->
        res.status(200).send "Success!"

    helper "post", "/__appgyver/generate", (req, res) =>
      res.header "Access-Control-Allow-Origin", "*"
      res.header "Access-Control-Allow-Headers", "Content-Type"

      Generators = require "../Generators"

      opts =
        name: req.body.name
        generatorOptions:
          name: req.body.parameters.name
          otherOptions: req.body.parameters.options

      unless Generators[opts.name]?
        error = "No such generator: #{opts.name}"
        res.status(404).json {error: error}
        return

      generator = new Generators[opts.name](opts.generatorOptions)

      generator.generate()
      .then ->
        res.status(200).send "Success!"
      .catch (error)->
        message = "#{error.message}"
        res.status(404).json {error: message}

    helper "get", "/__appgyver/emulators/:emulator/:action", (req, res) =>
      emulator = req.param("emulator")
      action = req.param("action")

      if emulator == "android"
        Android = require "../emulate/android"
        emulate = new Android()
      else if emulator == "genymotion"
        Genymotion = require "../emulate/genymotion"
        emulate = new Genymotion()
      else if emulator == "simulator"
        Simulator = require "../Simulator"
        emulate = new Simulator()
      else
        res.status(500).json { error: "Invalid emulator" }

      emulate.run().then () ->
        steroidsCli.log "Emulator started"
        res.status(200).json  { message: "Launched" }
      .catch (err) ->
        steroidsCli.log err.message
        res.status(500).json { error: err.message }

    @app.options "/__appgyver/logger", (req, res) =>
      res.header "Access-Control-Allow-Origin", "*"
      res.header "Access-Control-Allow-Headers", "Content-Type"

      res.end ''

    @app.get "/__appgyver/logger", (req, res) =>
      res.header "Access-Control-Allow-Origin", "*"
      res.header "Access-Control-Allow-Headers", "Content-Type"

      options = {
        from: req.param "from"
      }

      winston.query options, (err, results) ->
        if (err)
          throw err

        res.send results.file
        res.end ''

    @app.post "/__appgyver/logger", (req, res) =>
      res.header "Access-Control-Allow-Origin", "*"
      res.header "Access-Control-Allow-Headers", "Content-Type"
      res.end ''

      logMsg = req.body

      #unused stuff coming in from Steroids.js:
      #  .screen_id, .layer_id, .view_id

      clientResolver = new ClientResolver(req)
      resolvedClient = clientResolver.resolve()

      logLevel = logMsg.level || "info"
      message = logMsg.message
      metadata =
        datetime: logMsg.date
        view: logMsg.location
        host: req.headers.host
        device: resolvedClient.device

      winston.log logLevel, message, metadata

    @app.get "/__appgyver/clients", (req, res) =>
      res.header "Access-Control-Allow-Origin", "*"
      res.header "Access-Control-Allow-Headers", "Content-Type"

      res.send
        clients: @clients

    @app.get "/__appgyver/access_token", (req, res) =>
      res.header "Access-Control-Allow-Origin", "*"
      res.header "Access-Control-Allow-Headers", "Content-Type"

      Login = require "../Login"

      if Login.currentAccessToken()
        res.status(200).send Login.currentAccessToken()
      else
        res.status(404).json {error: "Not authenticated"}

    @app.get "/refresh_client?:timestamp", (req, res) =>
      res.header "Access-Control-Allow-Origin", "*"

      clientResolver = new ClientResolver(req)
      resolvedClient = clientResolver.resolve()

      client = if @clients[req.ip]
        @clients[req.ip]
      else

        platform = if resolvedClient.isAndroid
          "android"
        else
          "ios"

        updater = new Updater()
        updater.checkClient
          platform: platform
          version: resolvedClient.version
          simulator: resolvedClient.isSimulator
          osVersion: resolvedClient.osVersion
          device: resolvedClient.device

        {
          ipAddress: req.ip
          firstSeen: Date.now()
          userAgent: req.headers["user-agent"]
          new: true
          platform: platform
          version: resolvedClient.version
          osVersion: resolvedClient.osVersion
          device: resolvedClient.device
          simulator: resolvedClient.isSimulator
        }

      client.lastSeen = Date.now()
      @clients[req.ip] = client

      timestamp = key for key,val of req.query

      if fs.existsSync Paths.temporaryZip
        filestamp = fs.lstatSync(Paths.temporaryZip).mtime.getTime()
      else
        filestamp = 0

      if parseInt(filestamp,10) > parseInt(timestamp,10)
        res.send "true"
      else
        res.send "false"


module.exports = BuildServer
