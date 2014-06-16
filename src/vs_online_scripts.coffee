# Description:
#   A way to interact with Visual Studio Online.
#
# Commands:
#   hubot vso show room defaults - Displays room settings
#   hubot vso set room default <key> = <value> - Sets room setting <key> with value <value>
#   hubot vso getbuilds - Will return a list of build definitions, along with their build number.
#   hubot vso build <build number> - Triggers a build of the build number specified.
#   hubot vso createpbi <title> with description <description> - Create a Product Backlog work item with the title and descriptions specified.  This will put it in the root areapath and iteration
#   hubot vso createbug <title> with description <description> - Create a Bug work item with the title and description specified.  This will put it in the root areapath and iteration
#   hubot vso what have i done today - This will show a list of all tasks that you have updated today

Client = require 'vso-client'
util = require 'util'

VSO_CONFIG_KEYS_WHITE_LIST = [
  "project"
]

class VsoData
  
  constructor: (robot) ->
    @vsoData = robot.brain.data.vsonline ||= 
      rooms: {}
      
  roomDefaults: (room) ->
    return @vsoData.rooms[room] ||= {}
    
  getRoomDefault: (room, key) ->
    return @vsoData.rooms[room]?[key]

module.exports = (robot) ->  
  username = process.env.HUBOT_VSONLINE_USER_NAME
  password = process.env.HUBOT_VSONLINE_PASSWORD
  account = process.env.HUBOT_VSONLINE_ACCOUNT
  url = "https://#{account}.visualstudio.com"
  collection = process.env.HUBOT_COLLECTION_NAME || "DefaultCollection"

  vsoData = () => @_vsoData ||= new VsoData(robot)

  checkRoomDefault = (msg, key) ->
    val = vsoData().getRoomDefault msg.envelope.room, key
    msg.reply "Error: room default '#{key}' not set" unless val
    return val
    
  robot.respond /vso show room defaults/i, (msg)->
    defaults = vsoData().roomDefaults msg.envelope.room
    reply = "VSOnline defaults for this room:\n"
    reply += "#{key}: #{defaults?[key] or 'Not set'} \n" for key in VSO_CONFIG_KEYS_WHITE_LIST
    msg.reply reply    
    
  robot.respond /vso set room default ([\w]+)\s*=\s*(.*)\s*$/i, (msg) ->
    return msg.reply "Unknown setting #{msg.match[1]}" unless msg.match[1] in VSO_CONFIG_KEYS_WHITE_LIST
    defaults =  vsoData().roomDefaults(msg.envelope.room)
    defaults[msg.match[1]] = msg.match[2]
    msg.reply "Room default for #{msg.match[1]} set to #{msg.match[2]}"
    
  robot.respond /show vsonline projects/i, (msg) ->
    client = Client.createClient(url, collection, username, password)
    client.getProjects (err, projects) ->
      return console.log err if err
      reply = "VSOnline projects for account #{account}: \n"
      reply += p.name + "\n" for p in projects
      msg.reply reply

  robot.respond /vso show builds/i, (msg) ->
    return unless project = checkRoomDefault msg, "project"
    definitions=[]
    client = Client.createClient(url, collection, username, password)
    client.getBuildDefinitions (err, buildDefinitions) ->
      if err
        console.log err
      definitions.push "Here are the current build definitions: "              
      for build in buildDefinitions                                           
        definitions.push build.name + ' ' + build.id      
      msg.send definitions.join "\n"   


  robot.respond /vso build (.*)/i, (msg) ->    
    buildId = msg.match[1]    
    client = Client.createClient(url, collection, username, password)    
    buildRequest =
      definition:
        id: buildId
      reason: 'Manual'
      priority : 'Normal'

    client.queueBuild buildRequest, (err, buildResponse) ->
      if err
        console.log err
      msg.send "Build queued.  Hope you you don't break the build! " + buildResponse.url

  robot.respond /vso CreatePBI (.*) (with description) (.*)/i, (msg) ->
    return unless project = checkRoomDefault msg, "project"

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
               
    client = Client.createClient(url, collection, username, password);    
    client.createWorkItem workItem, (err,createdWorkItem) ->      
      if err
        console.log err
      msg.send "PBI " + createdWorkItem.id + " created.  " + createdWorkItem.webUrl

  robot.respond /vso CreateBug (.*) (with description) (.*)/i, (msg) ->
    return unless project = checkRoomDefault msg, "project"
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
               
    client = Client.createClient(url, collection, username, password);
    client.createWorkItem workItem, (err,createdWorkItem) ->       
      if err
        console.log err     
      msg.send "BUG " + createdWorkItem.id + " created.  " + createdWorkItem.webUrl
    
   
  robot.respond /What have I done today/i, (msg) ->        
    return unless project = checkRoomDefault msg, "project"
  
    myuser = msg.message.user.displayName

    wiql="select [System.Id], [System.WorkItemType], [System.Title], [System.AssignedTo], [System.State], [System.Tags] from WorkItems where [System.WorkItemType] = 'Task' and [System.ChangedBy] = '" + myuser + "' and [System.ChangedDate] = @today"
    
    #console.log wiql
    client = Client.createClient(url, collection, username, password)

    client.getRepositories null, (err,repositories) ->     
      if err
        console.log err             
      mypushes=[]
      today = yesterdayDate() 
      for repo in repositories             
        client.getCommits repo.id, null, myuser, null,today,(err,pushes) ->
          if err
            console log err                 
          numPushes = Object.keys(pushes).length    
          if numPushes >0             
            mypushes.push "You have written code!  These are your commits for the " + repo.name + " repo"                               
            for push in pushes                          
              mypushes.push "commit" + push.commitId                   
            msg.send mypushes.join "\n"
    tasks=[]
    client.getWorkItemIds wiql, project, (err, ids) ->
      if err
        console.log err                      
      numTasks = Object.keys(ids).length 
      if numTasks >0
        workItemIds=[]      
        for id in ids       
          workItemIds.push id
         
        client.getWorkItemsById workItemIds, null, null, null, (err, items) ->
          if err
            console.log err                 
          tasks.push "You have worked on the following tasks today: "
        
           
          for task in items        
            for item in task.fields
              if item.field.name == "Title"                                    
                tasks.push item.value         
                msg.send tasks.join "\n" 

yesterdayDate = () ->
  date = new Date()
  date.setDate(date.getDate() - 1);
  date.setUTCHours(0,0,0,0);
  date.toISOString()