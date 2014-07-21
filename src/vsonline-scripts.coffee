# Description:
#   A way to interact with Visual Studio Online.
#
# Dependencies:
#    "node-uuid": "~1.4.1"
#    "hubot": "~2.7.5"
#    "vso-client": "~0.1.7"
#    "parse-rss":  "~0.1.1"
#
# Configuration:
#   HUBOT_VSONLINE_ACCOUNT - The Visual Studio Online account name (Required)
#   HUBOT_VSONLINE_USERNAME - Alternate credential username (Required in trust mode)
#   HUBOT_VSONLINE_PASSWORD - Alternate credential password (Required in trust mode)
#   HUBOT_VSONLINE_APP_ID - Visual Studion Online application ID (Required in impersonate mode)
#   HUBOT_VSONLINE_APP_SECRET - Visual Studio Online application secret (Required in impersonate mode)
#   HUBOT_VSONLINE_AUTHORIZATION_CALLBACK_URL - Visual Studio Online application oauth callback (Required in impersonate mode)
#
# Commands:
#   hubot vso room defaults - Shows room defaults (e.g. project, etc)
#   hubot vso room default <key> = <value> - Sets a room default project, etc.
#   hubot vso builds - Shows a list of build definitions
#   hubot vso build <build definition number> - Triggers a build
#   hubot vso create pbi|bug|feature|impediment|task <title> with description <description> - Creates a work item, and optionally sets a description (repro step for some work item types)
#   hubot vso today - Shows work items you have touched and code commits you have made today
#   hubot vso commits [last <number> days] - Shows a list of commits you have made in the last day (or specified number of days)
#   hubot vso projects - Shows a list of projects
#   hubot vso me - Shows info about your Visual Studio Online profile
#   hubot vso forget credentials - Removes the access token issued to Hubot when you accepted the authorization request
#   hubot vso status - Shows status for the Visual Studio Online service
#   hubot vso help <search text> - Get help from VS related forums about the <search text>
#
# Notes:

Client = require 'vso-client'
util = require 'util'
uuid = require 'node-uuid'
request = require 'request'
rssParser = require 'parse-rss'
{TextMessage} = require 'hubot'


#########################################
# Constants
#########################################
VSO_TOKEN_CLOSE_TO_EXPIRATION_MS = 120*1000

VSO_STATUS_URL = "http://www.visualstudio.com/support/support-overview-vs"

ID_LIST = "Ids"

#########################################
# Helper class to manage VSOnline brain 
# data
#########################################
class VsoData
  
  constructor: (robot) ->
  
    ensureVsoData = ()=>
      robot.logger.debug "Ensuring vso data correct structure"
      @vsoData ||= {}    
      @vsoData.rooms ||= {}
      @vsoData.authorizations ||= {}
      @vsoData.authorizations.states ||= {}
      @vsoData.authorizations.users ||= {}
      robot.brain.set 'vsonline', @vsoData 
  
    # try to read vso data from brain
    @loaded = false
    @vsoData = robot.brain.get 'vsonline'
    if not @vsoData
      ensureVsoData()
      # and now subscribe for the onload for cases where brain is loading yet
      robot.brain.on 'loaded', =>
        return if @loaded is true
        robot.logger.debug "Brain loaded. Recreate vso data with the data loaded from brain"
        @loaded = true
        @vsoData = robot.brain.get 'vsonline'
        ensureVsoData()
    else
      ensureVsoData()
                
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
  # The definition of team defaults.
  teamDefaultsList = {
    "project":
      help: "Project not set. Set with hubot vso set room default project = <project name or ID>"
    "area path":
      help: "Area path not set. Set with hubot vso set room default area path = <area path>"
    "repositories":
      help: "Repositories. Set with hubot vso set room default repositories = <1 or more, comma-separated repository IDs or names>"
      callback : (msg, room, configName, wantedRepositories) -> 
        setDefaultRepositories msg, configName, wantedRepositories
      #callback : @setDefaultRepositories
  }


  # Required env variables
  account = process.env.HUBOT_VSONLINE_ACCOUNT
  accountCollection = process.env.HUBOT_VSONLINE_COLLECTION_NAME || "DefaultCollection"

  # Optional env variables to allow override a different environment
  environmentDomain = process.env.HUBOT_VSONLINE_ENV_DOMAIN || "visualstudio.com"
  
  # Required env variables to run in trusted mode
  username = process.env.HUBOT_VSONLINE_USERNAME
  password = process.env.HUBOT_VSONLINE_PASSWORD
    
  # Required env variables to run with OAuth (impersonate mode)
  appId = process.env.HUBOT_VSONLINE_APP_ID
  appSecret = process.env.HUBOT_VSONLINE_APP_SECRET
  oauthCallbackUrl = process.env.HUBOT_VSONLINE_AUTHORIZATION_CALLBACK_URL
  
  # OAuth optional env variables
  spsBaseUrl = process.env.HUBOT_VSONLINE_BASE_VSSPS_URL or "https://app.vssps.visualstudio.com"
  authorizedScopes = process.env.HUBOT_VSONLINE_AUTHORIZED_SCOPES or "preview_api_all preview_msdn_licensing"
  
  accountBaseUrl = "https://#{account}.#{environmentDomain}"
  impersonate = if appId then true else false
  robot.logger.info "VSOnline scripts running with impersonate set to #{impersonate}"
  
  if impersonate
    oauthCallbackPath = require('url').parse(oauthCallbackUrl).path
    accessTokenUrl = "#{spsBaseUrl}/oauth2/token"
    authorizeUrl = "#{spsBaseUrl}/oauth2/authorize"
  
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
    return msg.reply "You must authorize Hubot to interact with Visual Studio Online on your behalf: #{vsoAuthorizeUrl}"
      
  getVsoOAuthAccessToken = ({user, assertion, refresh, success, error}) ->
    tokenOperation = if refresh then Client.refreshToken else Client.getToken
    
    tokenOperationCallback =  (err, res) ->
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
    
    tokenOperation appSecret, assertion, oauthCallbackUrl, tokenOperationCallback, accessTokenUrl
        
        
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
      Client.createOAuthClient url, collection, token.access_token, { spsUri: spsBaseUrl }
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
          msg.reply "Your authorization to Hubot has been revoked or has expired."

    else
      vsoCmd()
      
  handleVsoError = (msg, err) ->
    msg.reply "Unable to execute command: #{util.inspect(err)}" if err
    
  #########################################
  # Room defaults helper functions
  #########################################
  checkRoomDefault = (msg, key) ->
    val = vsoData.getRoomDefault msg.envelope.room, key
    unless val
      help = teamDefaultsList[key]?.help or
        "Room default '#{key}' not set."
      msg.reply help
      
    return val

  setRoomDefault = (msg, configName, value) ->    
    vsoData.addRoomDefault msg.envelope.room, configName, value
    msg.reply "Room default #{configName} is now set to #{value}"
  
  setDefaultRepositories = (msg, configName, wantedRepositories) ->
  
    runVsoCmd msg, cmd: (client) ->

      client.getRepositories null, (err,repositories) ->
        return handleVsoError msg, err if err
      
        if repositories.length == 0
          msg.reply "No Git repositories found. No default is being set"
        else
          wantedRepositoriesList = wantedRepositories.split ","
          filteredRepoList = []
          filteredRepoNameList = []
          
          for repo in repositories
            if wantedRepositoriesList.indexOf(repo.id) != -1 or wantedRepositoriesList.indexOf(repo.name) != -1
              filteredRepoList.push { 
                "id" : repo.id 
                "name" : repo.name
              }
              filteredRepoNameList.push repo.name
        
          if filteredRepoList.length == 0
            msg.reply "No Git repositories found with the names or ids specified.\nNo default value changed"
          else            
            vsoData.addRoomDefault msg.envelope.room, configName + ID_LIST, filteredRepoList
            setRoomDefault msg, configName, filteredRepoNameList.join ","
            

  #########################################
  # OAuth call back endpoint
  #########################################
  if impersonate then robot.router.get oauthCallbackPath, (req, res) ->
    
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
        robot.receive new TextMessage stateData.envelope.user, stateData.envelope.message.text
      error: (err, resVso) ->
        robot.logger.error "Failed to get OAuth access token: " + util.inspect(err or resVso.Error)
        res.send """
          <html>
            <body>
            <p>Ooops! It wasn't possible to get an OAuth access token for you.</p>
            <p>Error returned from VSO: #{util.inspect(err or resVso.Error)}</p>
            </body>
          </html>"""
          
  #########################################
  # Profile related commands
  #########################################
  robot.respond /vso me(\?)*/i, (msg) ->
    unless impersonate
      return msg.reply "Hubot is not running in impersonation mode."

    runVsoCmd msg, cmd: (client) ->
      client.getCurrentProfile (err, res) ->
        return handleVsoError msg, err if err
        msg.reply "Your name is #{res.displayName} \
          and your email is #{res.emailAddress}"           

  robot.respond /vso forget credentials/i, (msg) ->
    unless impersonate
      return msg.reply "Hubot is not running in impersonation mode."
    
    vsoData.removeOAuthTokenForUser msg.envelope.user.id
    msg.reply "Hubot has removed your credentials and is no longer able to act on your behalf."

  #########################################
  # Room defaults related commands
  #########################################
  robot.respond /vso room defaults/i, (msg)->
    defaults = vsoData.roomDefaults msg.envelope.room
    reply = "Defaults for this room:\n"
    reply += "#{key} is #{defaults?[key] or '{not set}'} \n" for key of teamDefaultsList
    msg.reply reply
    
  robot.respond /vso room default ([\w]+)\s*=\s*(.*)\s*$/i, (msg) ->
    configName = msg.match[1]
    value = msg.match[2]    
 
    return msg.reply "This is not a known room setting: #{msg.match[1]}" unless configName of teamDefaultsList  
    
    if teamDefaultsList[configName]?.callback
      teamDefaultsList[configName].callback msg.envelope.room, configName, value
    else 
      setRoomDefault msg, configName, value
    
  robot.respond /vso projects/i, (msg) ->
    runVsoCmd msg, cmd: (client) ->
      client.getProjects (err, projects) ->
        return handleVsoError msg, err if err
        reply = "Projects in account #{account}: \n"
        reply += p.name + "\n" for p in projects
        msg.reply reply

  #########################################
  # Build related commands
  #########################################
  robot.respond /vso builds/i, (msg) ->
    runVsoCmd msg, cmd: (client) ->
      definitions=[]
      client.getBuildDefinitions (err, buildDefinitions) ->
        return handleVsoError msg, err if err
        
        if buildDefinitions.length == 0
          msg.reply "No build definitions have been configured (or are visible to you)" 
        else        
          definitions.push "Build definitions in account #{account}:"
          for build in buildDefinitions
            definitions.push "{build.name} (#{build.id})"    
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
        msg.reply "A build has been queued (hope you don't break it): " + buildResponse.url

  #########################################
  # WIT related commands
  #########################################
  robot.respond /vso create (PBI|Task|Feature|Impediment|Bug) (?:(?:(.*) with description($|[\s\S]+)?)|(.*))/im, (msg) ->
    return unless project = checkRoomDefault msg, "project"

    addField = (wi, wi_refName, val) ->
      workItemField=
        field: 
          refName : wi_refName
        value : val
      wi.fields.push workItemField

    runVsoCmd msg, cmd: (client) ->
      title = msg.match[2] || msg.match[4]
      description = msg.match[3]
      workItem=
        fields : []

      description = description.replace(/\n/g,"<br/>") if description
						
      addField workItem, "System.Title", title          
      addField workItem, "System.AreaPath", project
      addField workItem, "System.IterationPath", project      
		
      switch msg.match[1]      
        when "pbi"
          addField workItem, "System.WorkItemType", "Product Backlog Item"
          addField workItem, "System.State", "New"
          addField workItem, "System.Reason", "New Backlog Item"
          addField workItem, "System.Description", description
        when "task"
          addField workItem, "System.WorkItemType", "Task"
          addField workItem, "System.State", "To Do"
          addField workItem, "System.Reason", "New Task"
          addField workItem, "System.Description", description
        when "feature"
          addField workItem, "System.WorkItemType", "Feature"
          addField workItem, "System.State", "New"
          addField workItem, "System.Reason", "New Feature"
          addField workItem, "Microsoft.VSTS.Common.Priority","2"
          addField workItem, "System.Description", description
        when "impediment"
          addField workItem, "System.WorkItemType", "Impediment"
          addField workItem, "System.State", "Open"
          addField workItem, "System.Reason", "New Impediment"
          addField workItem, "Microsoft.VSTS.Common.Priority","2"
          addField workItem, "System.Description", description
        when "bug"
          addField workItem, "System.WorkItemType", "Bug"
          addField workItem, "System.State", "New"
          addField workItem, "System.Reason", "New Defect Reported"     
          addField workItem, "Microsoft.VSTS.TCM.ReproSteps", description	  
		  
      client.createWorkItem workItem, (err, createdWorkItem) ->        
        return handleVsoError msg, err if err
        msg.reply "Work item #" + createdWorkItem.id + " created: " + createdWorkItem.webUrl		     
    
  robot.respond /vso today/i, (msg) ->
    return unless project = checkRoomDefault msg, "project"
    return unless checkRoomDefault msg, "repositories"
  
    repositories = checkRoomDefault msg, "repositories" + ID_LIST

    runVsoCmd msg, cmd: (client) ->
    
      #TODO - we need to change to get the user profile from VSO
      myuser = msg.message.user.displayName

      wiql="\
        select [System.Id], [System.WorkItemType], [System.Title] \
        from WorkItems where [System.ChangedDate] = @today \
        and [System.ChangedBy] = " + getWIQLUserIdentityFor msg
              
      getCommitsForUser repositories, 1, msg, (pushes, repo) ->
        numPushes = Object.keys(pushes).length
        mypushes=[]
        if numPushes > 0
          mypushes.push "Here are your commits in Git repository " + repo.name + ":" 
          for push in pushes
            mypushes.push formatGitCommit(push)
          msg.reply mypushes.join "\n"
        else
          msg.reply "No code commits found for you today on Git repository " + repo.name
               
      workItems = []
      client.getWorkItemIds wiql, project, (err, ids) ->
        return handleVsoError msg, err if err
        
        numWorkItems = Object.keys(ids).length
        if numWorkItems > 0
          workItemIds=[]
          workItemIds.push id for id in ids
         
          client.getWorkItemsById workItemIds, null, null, null, (err, items) ->
            return handleVsoError msg, err if err
            if items and items.length > 0
              workItems.push "Here are the work items you have touched today on project " + project + ":"        
           
              for workItem in items              
                for item in workItem.fields				
                  if item.field.refName == "System.Title"
                    title = item.value
                  
                  if item.field.refName == "System.WorkItemType"
                    witType = item.value
					              
                workItems.push witType + " #" + workItem.id + ": " + title if title? and witType?
              			  
              msg.reply workItems.join "\n"
        else
          msg.reply "You have not touched any work items on project " + project + " today."
      
  robot.respond /vso commits *(last (\d+))?/i, (msg) ->
    return unless checkRoomDefault msg, "repositories"
    repositories = checkRoomDefault msg, "repositories" + ID_LIST  
    
    getCommitsForUser repositories, (if msg.match.length > 2 and msg.match[2] then msg.match[2] else 1), msg, (pushes, repo) ->

      numPushes = Object.keys(pushes).length
      mypushes=[]
      if numPushes > 0
        mypushes.push "Here are your commits in rep " + repo.name + ":"
        for push in pushes
          mypushes.push formatGitCommit(push)
        msg.reply mypushes.join "\n"
      else
        msg.reply "No code commits found for you today on Git repository " + repo.name


  formatGitCommit = (push) ->
    if push.comment.length > 77
      comment = push.comment.substring(0,77) + "..."
    else
      comment = push.comment
  
    return comment + " " + push.url

  getCommitsForUser = (repositories, sinceDays, msg, callback) ->
    runVsoCmd msg, cmd: (client) ->
      #TODO - we need to change to get the user profile from VSO
      myuser = msg.message.user.displayName      
      dateToSearchFrom = getStartDate(sinceDays)
        
      if repositories.length == 0
        msg.reply "No Git repositories found."
      else
        # use forEach to have a closure for repo        
        repositories.forEach (repo) ->
          client.getCommits repo.id, null, myuser, null, dateToSearchFrom, (err,commits) -> 
            return handleVsoError msg, err if err
            callback commits, repo


  getWIQLUserIdentityFor = (msg) ->
    if impersonate
      return "@me"    
    else
      return "'" + msg.envelope.user.replace("'","''") + "'"
      

  #########################################
  # Visual Studio Online Status related commands
  #########################################
  robot.respond /vso status/i, (msg) ->
    request "https://www.windowsazurestatus.com/odata/ServiceCurrentIncidents?api-version=1.0&$filter=startswith(Name,'#{escape("Visual Studio")}')" , (err, response, body) -> 
      if(err)
        robot.logger.error "Error getting status: #{util.inspect(err)}"
        msg.reply "Unable to get the current status of Visual Studio Online. Visit #{VSO_STATUS_URL}" 
      else
        if response.statusCode == 200
          status = JSON.parse body      
          serviceStatusResponse = "Here is the current status of Visual Studio Online:\n" 
          for vsoService in status.value
           serviceStatusResponse += vsoService.Name + " (" + vsoService.Status + ")\n"  
          serviceStatusResponse += "Full details: #{VSO_STATUS_URL}"
          msg.reply serviceStatusResponse
        else
          msg.reply "Failed to get Visual Studio Online status. HTTP error code was " + response.statusCode
		  


  #########################################
  # MSDN related commands
  #########################################
  robot.respond /vso help (.*)/i, (msg) ->
    searchText = msg.match[1]
  
    url = getRSSSearchUrl searchText
    
    robot.logger.debug "searching " + url

    rssParser url, (err,rss) ->
      if(err) 
        robot.logger.error "error searching MSDN " + err
        msg.reply "Failed to get Visual Studio Online help. Error: " + err
      else if rss.length == 0
        msg.reply "No results were found."
      else        
        searchResults = "Here are your results:\n"
        for item in rss
          searchResults += "#{item.title} #{item.link}\n"
        searchResults += "\nFor full results: " + getSearchUrl searchText      
      
        msg.reply searchResults

  getRSSSearchUrl = (searchString) ->
    return "http://social.msdn.microsoft.com/search/en-US/feed?format=RSS&theme=vscom&refinement=198%2c234&query=#{escape(searchString)}"
    
  getSearchUrl = (searchString) ->           
    return "http://social.msdn.microsoft.com/Search/en-US/vscom?Refinement=198,234&emptyWatermark=true&ac=4&query=#{escape(searchString)}"


  #########################################
  # Unhandled VSO command
  #########################################
  robot.catchAll (msg) ->
    return unless msg.message.text.toLowerCase().indexOf(" vso ") isnt -1
    msg.send """This command was not understood: #{msg.message.text}.
      Run 'hubot help vso' to see a list of Visual Studio Online commands."""

getStartDate = (numDays) ->
  date = new Date()
  date.setDate(date.getDate() - numDays)
  date.setUTCHours(0,0,0,0)
  date.toISOString()
