# BoxWallet #

BoxWallet is a CLI application that makes it very easy to set up and view a CLI wallet, by just using the command line on the platform of your choosing, with a single command.

## What is BoxWallet used for? ###

* Making the initial installation of a DIVI or PHORE wallet trivial with the single command `./boxwallet install`
* Web enabling your existing wallet.
* Displaying the staking status of your wallet. 
* Displaying blockchain and master node syncing status
* Displaying of block count and network difficulty
* Displaying of % coins required for staking. (for DIVI)
* Auto fixing common wallet issues.
* Balance in DIVI/PHORE, USD, AUD and GBP (more coming soon...)

### How do I run? ###

* Download the archived file, for the platform of your choosing, extract the files and simply run: `./boxwallet install`

This will download the official binaries from the coin's Project website, and installs the BoxWallet CLI app.

Then, change to the `boxwallet` folder in your home folder, and run `./boxwallet start`, to start the coin's damon server and then you can run  `./boxwallet dash`, where you should be prompted through an initial wizard to get you going.

### OK, but what else can BoxWallet do? ###

* Creates an initial wallet from scratch, for the coin of your choosing.

* Takes you through an initial wizard to ensure your wallet is secure.

* `boxwallet install` - Installs the official coin project CLI files, and creates a new wallet.

* `boxwallet dash` - Displays blockchain, syncing, staking and coin balance and AUD/USD/GBP (Divi only) balance info.

* `boxwallet wallet encrypt/unlock/unlockfs` - Allows the encryption and unlocking of the wallet for safe staking.

* `boxwallet wallet displayaddress` - Displays your public coin address.

* Allows you to "web enable" your existing wallet.

## How do I setup a client/server environment?

There may be times when you have your coin server running on one machine (machine A), and you want to run BoxWallet on another machine (machine B). This is how you would achieve that.

### Configure machine A (The coin daemon server)

On the machine running the coin daemon server, edit the coin's conf file e.g. `divi.conf`, that's stored in the hidden folder `~/.divi/` and make sure it contains the following settings, which are explained below:

```
rpcuser=divirpc
rpcpassword=A_Random_Password

server=1
rpcallowip=192.168.1.0/255.255.255.0
rpcport=51473

```
The `server=1` tells `divid` to listen for requests from BoxWallet.

The `rpcallowip=192.168.1.0/255.255.255.0` line, tells the `divid` server what IP addresses to *allow* a connection from. So, in our example, any local ipaddress in the range of 192.168.1.1-254 would be able to connect to the `divid` server.

Finally, the `rpcport=51473` tells the `divid` server what port to listen on. e.g. `51473`

After the settings have been implemented, you'll need to restart your `divid` server which can be achieved by `./boxwallet stop` and then `./boxwallet start`.

### Configure machine B (The BoxWallet client)

Download the latest version of BoxWallet from the website, or just copy the files from an existing installation.

Edit the `cli.yml` config file, and make sure the following settings exist:
```
port: "51473"
rpcpassword: A_Random_Password
rpcuser: divirpc
serverip: 127.0.0.1

```

Make sure the `port`,`rpcuser` and `rpcpassword` are all the same as what it is in your `divi.conf` file on the server, and make sure the `serverip:` address, is set the same as the ipaddress as the server (machine A). In the above example, the `serverip: 127.0.0.1` would only work if BoxWallet was running on the *same* server as `divid`.

## Is it free? ##

Yes! BoxWallet is FREE to use, however, if you'd like to send a tip, please feel free:

DIVI: DSniZmeSr62wiQXzooWk7XN4wospZdqePt

## Thank you for trying and supporting BoxWallet