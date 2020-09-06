# BoxWallet #

BoxDivi is a CLI application that makes it very easy to set up and view a Divi wallet by just using the command line on the platform of your choosing, with a single command.

## What is BoxDivi used for? ###

* Making the initial installation of a Divi wallet trivial with the single command `./boxdivi install`
* Web enabling your existing wallet.
* Displaying the staking status of your wallet. 
* Displaying blockchain and master node syncing status
* Displaying of block count and network difficulty
* Displaying of % coins required for staking.
* Auto fixing common wallet issues.
* Balance in DIVI, USD, AUD and GBP (more coming soon...)

### How do I run? ###

* Download the zip file, extract the files and simply run it: `./boxdivi install`

This will download the official binaries from the Divi Project website, and installs the BoxDivi CLI app.

Then, change to the `boxdivi` folder in your home folder, and run `./boxdivi start`, to start the `divid` server and then you can run  `./boxdivi dash`, where you should be prompted through an initial wizard to get you going.

### OK, but what else can BoxDivi do? ###

* Creates an initial wallet from scratch

* Takes you through an initial wizard to ensure your wallet is secure.

* `boxdivi install` - Installs the official Divi project CLI files, and creates a new wallet.

* `boxdivi dash` - Displays blockchain, syncing, staking and DIVI and AUD/USD/GBP balance info.

* `boxdivi wallet encrypt/unlock/unlockfs` - Allows the encryption and unlocking of the wallet for safe staking.

* `boxdivi wallet displayaddress` - Displays your public Divi address.

* Allows you to "web enable" your existing wallet.

## How do I setup a client/server environment?

There may be times when you have your `divid` server running on one machine (machine A), and you want to run BoxDivi on another machine (machine B). This is how you would achieve that.

### Configure machine A (The `divid` server)

On the machine running the `divid` server, edit the `divi.conf` file, that's stored in the hidden folder `~/.divi/` and make sure it contains the following settings, which are explained below:

```
rpcuser=divirpc
rpcpassword=A_Random_Password

server=1
rpcallowip=192.168.1.0/255.255.255.0
rpcport=51473

```
The `server=1` tells `divid` to listen for requests from BoxDivi.

The `rpcallowip=192.168.1.0/255.255.255.0` line, tells the `divid` server what IP addresses to *allow* a connection from. So, in our example, any local ipaddress in the range of 192.168.1.1-254 would be able to connect to the `divid` server.

Finally, the `rpcport=51473` tells the `divid` server what port to listen on. e.g. `51473`

After the settings have been implemented, you'll need to restart your `divid` server which can be achieved by `./boxdivi stop` and then `./boxdivi start`.

### Configure machine B (The BoxDivi client)

Download the latest version of BoxDivi from the website, or just copy the files from an existing installation.

Edit the `cli.yml` config file, and make sure the following settings exist:
```
port: "51473"
rpcpassword: A_Random_Password
rpcuser: divirpc
serverip: 127.0.0.1

```

Make sure the `port`,`rpcuser` and `rpcpassword` are all the same as what it is in your `divi.conf` file on the server, and make sure the `serverip:` address, is set the same as the ipaddress as the server (machine A). In the above example, the `serverip: 127.0.0.1` would only work if BoxDivi was running on the *same* server as `divid`.

## Is it free? ##

Yes! BoxDivi is FREE to use, however, if you'd like to send a tip, please send DIVI only to the following DIVI address:

DSniZmeSr62wiQXzooWk7XN4wospZdqePt

## Thank you for trying and supporting BoxDivi