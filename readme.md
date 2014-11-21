## Hubot scripts for Visual Studio Online

A collection of Hubot scripts to perform tasks in Visual Studio Online.

### Introduction

Hubot scripts for Visual Studio Online provides many commands to perform
tasks in Visual Studio Online.

The scripts can run in two modes

+ Trusted mode: the tasks against Visual Studio Online are performed using
  the same account
+ Impersonate mode: the tasks against Visual Studio Online are perfomed on
  behalf of the user issuing the command. In this mode the user has to explicitly
  authorize hubot

### Installation

To install, in your Hubot instance directory

```
npm install hubot-vso-scripts
```


Include the package in your hubot's external-scripts.json

```
["hubot-vso-scripts"]
```

### Upgrade from 0.2.5 or previous version

If you are using impersonate mode (OAuth), you will need to re-register your application on Visual Studio Online.

This is needed, because version 1.0 has introduced a more granular scope and we now request
less permissions

You will need to register the application with the following permissions

 + Work items (read and write)
 + Build (read and execute)
 + Code (read)

Then you need to update you environment variables with your app id and your app secret (authorize URL stays the same)

The scripts will automatically detect the situation and ask the users to (re) authorize hubot scripts.

### Configuration

The required environment variables are

+ **HUBOT\_VSONLINE\_ACCOUNT** - The Visual Studio Online account's name

Message replies are by default sent in plaintext, but if your adapter is capable of receiving messanges in other
format you can configure the scripts to use a different formatting

+ **HUBOT\_VSONLINE\_REPLY\_FORMAT** The formatting of replies. You can use plaintext,html or markdown

*Trust Mode*

In trust mode we need to set the alternate credentials of the user who  will perform the tasks

+ **HUBOT\_VSONLINE\_USERNAME**: The alternate credentials username
+ **HUBOT\_VSONLINE\_PASSWORD**: The alternate credentials password

*Impersonate Mode*

In impersonate we need to set the variables defined in the application registered in Visual Studio Online
(Click [here](http://www.visualstudio.com/integrate/get-started-auth-oauth2-vsi) to know how to register an
application in Visual Studio Online

+ **HUBOT\_VSONLINE\_APP\_ID**: The application ID
+ **HUBOT\_VSONLINE\_APP\_SECRET**: The application secret
+ **HUBOT\_VSONLINE\_AUTHORIZATION\_CALLBACK\_URL**: The OAuth callback URL. This URL must be available from
  the chat service you're using


### License

MIT


