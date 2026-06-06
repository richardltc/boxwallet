# Installing Nexa

This document describes how to install and configure Nexa.

# Downloading Nexa

If you just want to run the Nexa software go to the
[Download](https://gitlab.com/nexa/nexa/-/releases/) page and get the relevant
files for your system.

If you are moving from another Nexa compatible implementation, make sure to follow this plan before moving:

- backup your wallet (if any)
- make a backup of the `~/.nexa` dir
- if you have installed nexa via apt using the ppa nexa repo:
   - `sudo apt-get remove nexa*`
   - `sudo rm /etc/apt/sources.list.d/nexa-*.*`
- if you have compile Nexa from source:
   - `cd /path/where/the/code/is/stored`
   - `sudo make uninstall`


## Windows

You can choose

- Download the setup file (exe), and run the setup program, or
- download the (zip) file, unpack the files into a directory, and then run nexa-qt.exe.


## Linux / Unix

Unpack the files into a directory and run:

- `bin/nexa-qt` (GUI) or
- `bin/nexad` (headless)

If you plan to run also Rostrum along with Nexa full node you need to make sure that both `nexad` and `rostrum` binary are stored on the same folder.


### Provide Blockchain Data Services to Everybody

Allowing other computers and phones to ask your machine for Nexa blockchain information is an important part of true decentralized permissionless anonymous blockchains like Nexa.  If you are running Linux, your help is especially valuable because you can also provide blockchain synthesis/summary information to other people.  To to this, see the section "Port Forwarding" below.


## macOS

Drag Nexa to your applications folder, and then run Nexa.

<!-- This is accepted as a comment too
# Installing Ubuntu binaries from Bitcoin Unlimited Official BU repositories)

If you're running an Ubuntu system you can install Bitcoin Unlimited from the official BU repository.)
The repository will provide binaries and debug symbols for 4 different architectures: i386, amd64, armhf and arm64. From a terminal do)


```sh
sudo apt-get install software-properties-common)
sudo add-apt-repository ppa:bitcoin-unlimited/bu-ppa)
sudo apt-get update)
sudo apt-get install nexad nexa-qt (# on headlesse server just install nexad))
```

Once installed you can run `nexad` or `nexa-qt`
-->


# Quick Startup and Initial Node operation

## QT or the command line:

There are two modes of operation, one uses the QT UI and the other runs as a daemon from the command line.  The QT version is nexa-qt or nexa-qt.exe, the command line version is nexad or nexad.exe. No matter which version you run, when you launch for the first time you will have to complete the intial blockchain sync.

## Initial Sync of the blockchain:

When you first run the node it must first sync the current blockchain.  All block headers are first retrieved and then each block is downloaded, checked and the UTXO finally updated.  This process can take from hours to *weeks* depending on the node configuration, and therefore, node configuration is crucial.

The most important configuration which impacts the speed of the initial sync is the `cache.dbcache` setting.  The larger the dbcache the faster the initial sync will be, therefore, it is vital to make this setting as high as possible.  If you are running on a Windows machine there is an automatically adjusting dbcache setting built in; it will size the dbcache in such a way as to leave only 10% of the physical memory free for other uses.  On Linux and other OS's the sizing is such that one half the physical RAM will be used as dbcache. While these settings, particularly on non Windows setups, are not ideal they will help to improve the initial sync dramatically.

However, even with the automatic configuration of the `cache.dbcache` setting it is recommended to set one manually if you haven't already done so (see the section below on Startup Configuration). This gives the node operator more control over memory use and in particular for non Windows setups, can further improve the performance of the initial sync.

## Startup configuration

There are dozens of configuration and node policy options available but the two most important for the initial blockchain sync are as follows.

### dbcache

As stated above, this setting is crucial to a fast initial sync. If you don't configure any value then the system
will automatically adjust this size for you, more or less. On windows the auto adjustment works very well and will rise and fall with your nodes needs, however, on linux/maxOS the adjustments are not as granular and so if your a power user
you will likely want to manually configure your dbcache settings.

You can set this value manually from the command line (or adding it to your nexa.conf) by running
```
nexad -cache.dbcache=<your size in MB>
```
For example, a 1GB dbcache would be
```
nexad -cache.dbcache=1000
```
Similarly you can also add the setting to the nexa.conf file located in your installation folder. In the config file a simlilar entry would be

```
cache.dbcache=1000`
```

When entering the size
try to give it the maximum that your system can afford while still leaving enough memory for other processes.

### Getting enough network connections

It is generally fine to leave the default inbound/outbound connection settings for doing a sync, however, at times some users have reported issues with not being able to find any useful connections. This is often a problem because too many nodes are looking for outbound connections but node operators have forgotten to configure for allowing inbound connections (if nobody allows inbound connections then there would be no network connectivity for anyone).

Note that you must have connections to the network in order to send or receive coins from you wallet!

#### Port Forwarding

To get inbound connections for Nexa require that port 7228 be port forwarded (TCP protocol).  Also forward port 20001 to enable Rostrum (blockchain data services for light clients).  If you don't know how to do this, see the next section!


##### Port Forwarding Guide for Beginners

To be a "full" member of the Nexa network, you'll want to configure your machine to provide blockchain data to wallets that need it.
Typically, this is not much bandwidth since the load is distributed across everybody and since dedicated machines handle much of it.
However, it is still useful for individuals to do this, because it will help resiliancy during network outages and it increases the
proportion of anonymous honest nodes providing accurate data.

To do this, you need to open certain ports in your internet router.  How to accomplish this is different for every router & there are very likely guides for your specific router on the internet that may do a better job than the following more general description:

First, go to your router's management web page (hopefully you remember what you set your router password to!!!) and figure out what IP your computer is being assigned.  You'll often find this in a section called "network map" or "local network" or "clients".  Or you can find it by looking in the networking details on your computer itself.  Note your computer's MAC (looks like aa:bb:cc:dd:ee:ff) and IP address (looks like a.b.c.d, or maybe aaaa:bbbb:cccc:dddd....).

Now your router typically assigns the same IP address to the same computer, but to guarantee that that happens, you want to look in your router's web page for a section called "DCHP" or "Address Reservation", and then add an entry containing the MAC and IP address of your computer.

Next, look for something called "Port Forwarding", often located in the "gaming" or "NAT forwarding" section of your router's web site.

Add an entry with your computer's IP address, "External Port" as 7228, "Internal Port" as 7228, and protocol as "TCP" (or all).
Next add another entry, again with your computer's IP address, "External Port" as 20001, "Internal Port" as 20001, and protocol as "TCP" (or all).

That's it!  External computers should now be able to ask you for Nexa blockchain data!  Thanks!


#### UPnP

Port forwarding is considered the better option, but if you don't want to setup port fowarding then you need to configure your router with UPnP turned on and then also turn on UPnP on nexad (-upnp=1), however, UPnP can be a security risk and so it is usually turned off by default on your router.


### Wallet Options

#### Paying a higher fee

Generally you don't need to make any changes to the default wallet configuration but when blocks become full for long periods of time, such as when exchanges consolidate dust, it can take a while to get your transactions to confirm. But by sending your transactions with a little higher fee than the minimum you can generally get confirmed in the next block.  The minimum fee is currently set at 1000 sat/byte however you can raise that fee by using the `wallet.payTxFee=<fee per Kb>` argument in your nexa.conf, or from the command line, and set it to something higher than 1000. By doing this your transactions will be mined before any lower fee transactions and so get confirmed quickly.

#### Using automatic fee estimation

If you don't want to set a fee you can use the fee estimator which will automatically try to figure out what the best fee would be to get a quick confirmation. To use this feature you can set `wallet.feeEstimation=1` in your nexa.conf or `-wallet.feeEstimation=1` from the command line.

#### Setting maximum fees

The Nexa wallet will limit your maximum fee you can add by default 10000 sat/byte, but if you prefer to set the value much lower you can with the `wallet.maxTxFee=<your max fee>` setting. Using this can protect you from accidentally sending very large fees, particularly if you are generating your own raw transactions.

#### Instant Transactions

When instant transactions is enabled the user can spend funds almost immediately upon receiving them in the wallet.  There is a default
five second delay to wait for potential double spend notifications but after that the user is free to spend their coins which are no yet
confirmed on the blockchain.  This feature also allows the user to do a "Child Pays for Parent" transaction, where an unconfirmed coin can
be spent to oneself with a higher fee and thus get quicker inclusion in a block if desired.

By default QT wallet users have instant transactions turned on whereas users running `nexad` will have it turned off by default. In order
to turn on instant transactions you can add  `-wallet.instant=true` as one of your startup options.

Other setings you can make are to the delay period and also the cutoff amount. To modify the instant delay you can add, for
example, `-wallet.instantDelay=2` where 2 is the number of seconds to wait for a double spend proof before confirming this transaction.
To modify the cutoff amount you can enter `wallet.instantLimit=10000000` which would prevent any transaction received with greater than
10000000 NEX from being considered as instantly confirmed (NOTE: if you set an instant cutoff value then any *tokens* you receive, other
than NEX, will not be considered as instantly confirmed and must wait for actual inclusion in a block before being spendable.).

### Minimize Disk Usage

If you are running Linux, its possible to minimize your disk usage by turning off Rostrum.  This prevents your node from providing light wallets
with blockchain data, so only do this if you are just running the full node wallet.  To do this, add this line to your nexa.conf configuration file:
```
electrum=0
```

# Getting help

 - [Issue Tracker](https://gitlab.com/nexa/nexa/issues)
 - [Reddit /r/nexa](https://www.reddit.com/r/nexa)
