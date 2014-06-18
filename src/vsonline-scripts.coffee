# Desription:
#   A way to interact with Visual Studio Online.
#
# Commands:
#   hubot vso show room defaults - Displays room settings
#   hubot vso set room default <key> = <value> - Sets room setting <key> with value <value>
#   hubot vso show builds - Will return a list of build definitions, along with their build number.
#   hubot vso build <build number> - Triggers a build of the build number specified.
#   hubot vso createpbi <title> with description <description> - Create a Product Backlog work item with the title and descriptions specified.  This will put it in the root areapath and iteration
#   hubot vso createbug <title> with description <description> - Create a Bug work item with the title and description specified.  This will put it in the root areapath and iteration
#   hubot vso what have i done today - This will show a list of all tasks that you have updated today
#   hubot vso show projects - Show the list of team projects
#   hubot vso who am i - Show user info as seen in Visual Studio Online user profile
#   hubot vso forget my credential - Forgets the OAuth access token 
#

Client = require 'vso-client'
util = require 'util'
uuid = require 'node-uuid'
{TextMessage} = require 'hubot' 

#########################################
# Constants
#########################################
VSO_CONFIG_KEYS_WHITE_LIST = {
  "project":
    help: "Project not set for this room. Set with hubot vso set room default project = {project name or ID}"
}

VSO_TOKEN_CLOSE_TO_EXPIRATION_MS = 120*1000

#########################################
# Helper class to manage VSOnline brain 
# data
#########################################
class VsoData
  
  constructor: (robot) ->
    @vsoData = robot.brain.get 'vsonline'
    unless @vsoData
      @vsoData = {}
      robot.brain.set 'vsonline', @vsoData
      
    @vsoData.rooms ||= {}
    @vsoData.authorizations ||= {}
    @vsoData.authorizations.states ||= {}
    @vsoData.authorizations.users ||= {} 
    
  roomDefaults: (room) ->
    @vsoData.rooms[room] ||= {}
    
  getRoomDefault: (room, key) ->
    @vsoData.rooms[room]?[key]
  
  addRoomDefault: (room, key, value) ->
    @roomDefaults(room)[key] = value
  
  getOAuthTokenForUser: (userId) ->
    @vsoData.authorizations.users[userId]
    
  addOAuthTokenForUser: (userId, token) ->
    @vsoData.authorizations.users[userId] = token
  
  removeOAuthTokenForUser: (userId) ->
    delete @vsoData.authorizations.users[userId]
    
  addOAuthState: (state, stateData) ->
    @vsoData.authorizations.states[state] = stateData
  
  getOAuthState: (state) ->
    @vsoData.authorizations.states[state]
    
  removeOAuthState: (state) ->
    delete @vsoData.authorizations.states[state]


module.exports = (robot) ->
  # Required env variables
  username = process.env.HUBOT_VSONLINE_USER_NAME
  password = process.env.HUBOT_VSONLINE_PASSWORD
  account = process.env.HUBOT_VSONLINE_ACCOUNT
  accountCollection = process.env.HUBOT_VSONLINE_COLLECTION_NAME || "DefaultCollection"
  
  # OAuth required env variables
  appId = process.env.HUBOT_VSONLINE_APP_ID
  appSecret = process.env.HUBOT_VSONLINE_APP_SECRET
  oauthCallbackUrl = process.env.HUBOT_VSONLINE_AUTHORIZATION_CALLBACK_URL
  
  # OAuth optional env variables
  vssPsBaseUrl = process.env.HUBOT_VSONLINE_BASE_VSSPS_URL or "https://app.vssps.visualstudio.com"
  authorizedScopes = process.env.HUBOT_VSONLINE_AUTHORIZED_SCOPES or "preview_api_all preview_msdn_licensing"
  oauthCallbackPath = process.env.HUBOT_VSONLINE_AUTHORIZATION_CALLBACK_PATH or "/hubot/oauth2/callback"
  
  accessTokenUrl = "#{vssPsBaseUrl}/oauth2/token"
  authorizeUrl = "#{vssPsBaseUrl}/oauth2/authorize"
  accountBaseUrl = "https://#{account}.visualstudio.com"
  impersonate = if appId then true else false
  
  robot.logger.info "VSOnline scripts running with impersonate set to #{impersonate}"

  vsoData = new VsoData(robot)

  robot.on 'error', (err, msg) ->
    robot.logger.error "Error in robot: #{util.inspect(err)}"

  #########################################
  # OAuth helper functions
  #########################################
  needsVsoAuthorization = (msg) ->
    return false unless impersonate
    
    userToken = vsoData.getOAuthTokenForUser(msg.envelope.user.id)
    return not userToken
    
  buildVsoAuthorizationUrl = (state)->
    "#{authorizeUrl}?\
      client_id=#{appId}\
      &response_type=Assertion&state=#{state}\
      &scope=#{escape(authorizedScopes)}\
      &redirect_uri=#{escape(oauthCallbackUrl)}"
      
  askForVsoAuthorization = (msg) ->
    state = uuid.v1().toString()
    vsoData.addOAuthState state,
      createdAt: new Date
      envelope: msg.envelope
    vsoAuthorizeUrl = buildVsoAuthorizationUrl state
    return msg.reply "I don't know who you are in Visual Studio Online.
      Click the link to authenticate #{vsoAuthorizeUrl}"
      
  getVsoOAuthAccessToken = ({user, assertion, refresh, success, error}) ->
    tokenOperation = if refresh then Client.refreshToken else Client.getToken
    tokenOperation appSecret, assertion, oauthCallbackUrl, (err, res) ->
      unless err or res.Error? 
        token = res
        expires_at = new Date
        expires_at.setTime(
          expires_at.getTime() + parseInt(token.expires_in, 10)*1000)

        token.expires_at = expires_at
        vsoData.addOAuthTokenForUser(user.id, token)
        success(err, res) if typeof success is "function"
      else
        robot.logger.error "Error getting VSO oauth token: #{util.inspect(err or res.Error)}"
        error(err, res) if typeof error is "function"
        
  accessTokenExpired = (user) ->
    token = vsoData.getOAuthTokenForUser(user.id)
    expiresAt = new Date token.expires_at
    now = new Date
    return (expiresAt - now) < VSO_TOKEN_CLOSE_TO_EXPIRATION_MS        

  #########################################
  # VSOnline helper functions
  #########################################
  createVsoClient = ({url, collection, user}) ->
    url ||= accountBaseUrl
    collection ||= accountCollection
    
    if impersonate
      token = vsoData.getOAuthTokenForUser user.id
      Client.createOAuthClient url, collection, token.access_token
    else
      Client.createClient url, collection, username, password
  
  runVsoCmd = (msg, {url, collection, cmd}) ->
    return askForVsoAuthorization(msg) if needsVsoAuthorization(msg)
    
    user = msg.envelope.user
    
    vsoCmd = () ->
      url ||= accountBaseUrl
      collection ||= accountCollection
      client = createVsoClient url: url, collection: collection, user: user
      cmd(client)
    
    if impersonate and accessTokenExpired(user)
      robot.logger.info "VSO token expired for user #{user.id}. Let's refresh"
      token = vsoData.getOAuthTokenForUser(user.id)
      getVsoOAuthAccessToken 
        user: user
        assertion: token.refresh_token
        refresh: true
        success: vsoCmd
        error: (err, res) ->
          msg.reply "Your VSO oauth token has expired and there\
            was an error refreshing the token.
            Error: #{util.inspect(err or res.Error)}"
    else
      vsoCmd()
      
  handleVsoError = (msg, err) ->
    msg.reply "Error executing command: #{util.inspect(err)}" if err
    
  #########################################
  # Room defaults helper functions
  #########################################
  checkRoomDefault = (msg, key) ->
    val = vsoData.getRoomDefault msg.envelope.room, key
    unless val
      help = VSO_CONFIG_KEYS_WHITE_LIST[key]?.help or
        "Error: room default '#{key}' not set."
      msg.reply help
      
    return val    

  #########################################
  # OAuth call back endpoint
  #########################################
  robot.router.get oauthCallbackPath, (req, res) ->
    
    # check state argument
    state = req?.query?.state
    return res.send(400, "Invalid state") unless state and stateData = vsoData.getOAuthState(state)

    # check code argument
    code = req?.query?.code
    return res.send(400, "Missing code parameter") unless code

    getVsoOAuthAccessToken
      user: stateData.envelope.user,
      assertion: code,
      refresh: false,
      success: -> 
        res.send """
          <html>
            <body>
            <p>Great! You've authorized Hubot to perform tasks on your behalf.
            <p>You can now close this window.</p>
            </body>
          </html>"""            
        vsoData.removeOAuthState state
        #console.log "Reinjecting message #{util.inspect(stateData)}"
        robot.receive new TextMessage stateData.envelope.user, stateData.envelope.message.text
      error: (err, res) ->
        res.send """
          <html>
            <body>
            <p>Ooops! It wasn't possible to get an OAuth access token for you.</p>
            <p>Error returned from VSO: #{util.inspect(err or res.Error)}</p>
            </body>
          </html>"""
          
  #########################################
  # Profile related commands
  #########################################
  robot.respond /vso who am i(\?)*/i, (msg) ->
    unless impersonate
      return msg.reply "It's not possible to know who you are since I'm running \
      with no impersonate mode."

    runVsoCmd msg, url: vssPsBaseUrl, collection: "/", cmd: (client) ->
      client.getCurrentProfile (err, res) ->
        return handleVsoError msg, err if err
        msg.reply "You're #{res.displayName} \
          and your email is #{res.emailAddress}"           

  robot.respond /vso forget my credential/i, (msg) ->
    unless impersonate
      return msg.reply "I'm not running in impersonate mode, \
      which means I don't have your credentials."
    
    vsoData.removeOAuthTokenForUser msg.envelope.user.id
    msg.reply "Done! In the next VSO command you'll need to dance OAuth again"

  #########################################
  # Room defaults related commands
  #########################################
  robot.respond /vso show room defaults/i, (msg)->
    defaults = vsoData.roomDefaults msg.envelope.room
    reply = "VSOnline defaults for this room:\n"
    reply += "#{key}: #{defaults?[key] or '<Not set>'} \n" for key of VSO_CONFIG_KEYS_WHITE_LIST
    msg.reply reply
    
  robot.respond /vso set room default ([\w]+)\s*=\s*(.*)\s*$/i, (msg) ->
    return msg.reply "Unknown setting #{msg.match[1]}" unless msg.match[1] of VSO_CONFIG_KEYS_WHITE_LIST
    vsoData.addRoomDefault(msg.envelope.room, msg.match[1], msg.match[2])
    msg.reply "Room default for #{msg.match[1]} set to #{msg.match[2]}"
    
  robot.respond /vso show projects/i, (msg) ->
    runVsoCmd msg, cmd: (client) ->
      client.getProjects (err, projects) ->
        return handleVsoError msg, err if err
        reply = "VSOnline projects for account #{account}: \n"
        reply += p.name + "\n" for p in projects
        msg.reply reply

  #########################################
  # Builds related commands
  #########################################
  robot.respond /vso show builds/i, (msg) ->
    runVsoCmd msg, cmd: (client) ->
      definitions=[]
      client.getBuildDefinitions (err, buildDefinitions) ->
        return handleVsoError msg, err if err
        
        definitions.push "Here are the current build definitions: "
        for build in buildDefinitions
          definitions.push build.name + ' ' + build.id
        msg.reply definitions.join "\n"

  robot.respond /vso build (.*)/i, (msg) ->
    buildId = msg.match[1]
    runVsoCmd msg, cmd: (client) ->
      buildRequest =
        definition:
          id: buildId
        reason: 'Manual'
        priority : 'Normal'

      client.queueBuild buildRequest, (err, buildResponse) ->
        return handleVsoError msg, err if err
        msg.reply "Build queued.  Hope you you don't break the build! " + buildResponse.url

  #########################################
  # Builds related commands
  #########################################
  robot.respond /vso CreatePBI (.*) (with description) (.*)/i, (msg) ->
    return unless project = checkRoomDefault msg, "project"

    runVsoCmd msg, cmd: (client) ->
      title = msg.match[1]
      descriptions = msg.match[3]
      workItem=
        fields : []

      titleField=
        field :
          refName : "System.Title"
        value :  title
      workItem.fields.push titleField
    
      typeField=
        field :
          refName : "System.WorkItemType"
        value :  "Product Backlog Item"
      workItem.fields.push typeField

      stateField=
        field:
          refName : "System.State"
        value :  "New"
      workItem.fields.push stateField

      reasonField=
        field:
          refName : "System.Reason"
        value :  "New Backlog Item"
      workItem.fields.push reasonField

      areaField=
        field:
          refName : "System.AreaPath"
        value :  project
      workItem.fields.push areaField

      iterationField=
        field:
          refName : "System.IterationPath"
        value :  project
      workItem.fields.push iterationField

      descriptionField=
        field:
          refName : "System.Description"
        value :  descriptions
      workItem.fields.push descriptionField

      client.createWorkItem workItem, (err, createdWorkItem) ->
        return handleVsoError msg, err if err
        msg.reply "PBI " + createdWorkItem.id + " created.  " + createdWorkItem.webUrl

  robot.respond /vso CreateBug (.*) (with description) (.*)/i, (msg) ->
    return unless project = checkRoomDefault msg, "project"
    
    runVsoCmd msg, cmd: (client)->
      title = msg.match[1]
      descriptions = msg.match[3]
      workItem=
        fields : []

      titleField=
        field :
          refName : "System.Title"
        value :  title
      workItem.fields.push titleField
    
      typeField=
        field :
          refName : "System.WorkItemType"
        value :  "Bug"
      workItem.fields.push typeField

      stateField=
        field:
          refName : "System.State"
        value :  "New"
      workItem.fields.push stateField

      reasonField=
        field:
          refName : "System.Reason"
        value :  "New Defect Reported"
      workItem.fields.push reasonField

      areaField=
        field:
          refName : "System.AreaPath"
        value :  project
      workItem.fields.push areaField

      iterationField=
        field:
          refName : "System.IterationPath"
        value :  project
      workItem.fields.push iterationField

      descriptionField=
        field:
          refName : "System.Description"
        value :  descriptions
      workItem.fields.push descriptionField
               
      client.createWorkItem workItem, (err,createdWorkItem) ->
        return handleVsoError msg, err if err
        msg.send "BUG " + createdWorkItem.id + " created.  " + createdWorkItem.webUrl
    
  robot.respond /vso What have I done today/i, (msg) ->
    return unless project = checkRoomDefault msg, "project"
  
    runVsoCmd msg, cmd: (client) ->
    
      #TODO - we need to change to get the user profile from VSO
      myuser = msg.message.user.displayName

      wiql="\
        select [System.Id], [System.WorkItemType], [System.Title], [System.AssignedTo], [System.State], \
        [System.Tags] from WorkItems where [System.WorkItemType] = 'Task' and [System.ChangedBy] = @me \
        and [System.ChangedDate] = @today"
    
      #console.log wiql

      client.getRepositories null, (err,repositories) ->
        return handleVsoError msg, err if err
        mypushes=[]
        today = yesterdayDate()
        for repo in repositories
          client.getCommits repo.id, null, myuser, null,today,(err,pushes) ->
            return handleVsoError msg, err if err
            numPushes = Object.keys(pushes).length
            if numPushes > 0
              mypushes.push "You have written code! These are your commits for the " + repo.name + " repo"
              for push in pushes
                mypushes.push "commit" + push.commitId
              msg.reply mypushes.join "\n"
              
      tasks=[]
      client.getWorkItemIds wiql, project, (err, ids) ->
        return handleVsoError msg, err if err
        numTasks = Object.keys(ids).length
        if numTasks >0
          workItemIds=[]
          workItemIds.push id for id in ids
         
          client.getWorkItemsById workItemIds, null, null, null, (err, items) ->
            return handleVsoError msg, err if err
            if items and items.length > 0
              tasks.push "You have worked on the following tasks today: "        
           
              for task in items
                for item in task.fields
                  if item.field.name == "Title"
                    tasks.push item.value
                    msg.reply tasks.join "\n"
        else
          msg.reply "You haven't worked on any task today"



yesterdayDate = () ->
  date = new Date()
  date.setDate(date.getDate() - 1)
  date.setUTCHours(0,0,0,0)
  date.toISOString()