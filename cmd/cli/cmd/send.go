package cmd

import (
	// "log"
	// "os"

	"fmt"
	"github.com/AlecAivazis/survey/v2"
	"github.com/spf13/cobra"
	"log"
	"os"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	xbc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinplus"
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/dogecash"
	ftc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/feathercoin"
	ltc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/litecoin"
	ppc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/peercoin"
	pivx "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/pivx"
	rdd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/reddcoin"
	sbyte "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/spiderbyte"
	tzc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/trezarcoin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/wallet"
	"time"
)

// sendCmd represents the send command
var sendCmd = &cobra.Command{
	Use:   "send",
	Short: "Send coins to another wallet",
	Long: `A longer description that spans multiple lines and likely contains examples
and usage of using your command. For example:

Cobra is a CLI library for Go that empowers applications.
This application is a tool to generate the needed files
to quickly create a Cobra application.`,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App

		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + app.Version() + "\n                                              \n                                               ")

		var conf conf.Conf
		var coinName coins.CoinName
		var daemonRunning coins.CoinDaemon
		var walletSecurityState wallet.WalletSecurityState
		var walletUnlock wallet.WalletUnlock
		var walletValidateAddress wallet.WalletVaidateAddress
		var sendToAddress wallet.WalletSendToAddress

		appHomeDir, err := app.HomeFolder()
		if err != nil {
			log.Fatal("Unable to get HomeFolder: " + err.Error())
		}

		conf.Bootstrap(appHomeDir)

		appFileName, err := app.FileName()
		if err != nil {
			log.Fatal("Unable to get appFilename: " + err.Error())
		}

		// Make sure the config file exists, and if not, force user to use "coin" command first..
		if _, err := os.Stat(appHomeDir + conf.ConfFile()); os.IsNotExist(err) {
			log.Fatal("Unable to determine coin type. Please run " + appFileName + " coin  first")
		}

		// Now load our config file to see what coin choice the user made...
		confDB, err := conf.GetConfig(true)
		if err != nil {
			log.Fatal("Unable to determine coin type. Please run " + appFileName + " coin: " + err.Error())
		}

		switch confDB.ProjectType {
		case models.PTBitcoinPlus:
			coinName = xbc.XBC{}
			daemonRunning = xbc.XBC{}
			walletSecurityState = xbc.XBC{}
			walletUnlock = xbc.XBC{}
			walletValidateAddress = xbc.XBC{}
			sendToAddress = xbc.XBC{}
		case models.PTDenarius:
		case models.PTDeVault:
		case models.PTDigiByte:
		case models.PTDivi:
			coinName = divi.Divi{}
			daemonRunning = divi.Divi{}
			walletSecurityState = divi.Divi{}
			walletUnlock = divi.Divi{}
			walletValidateAddress = divi.Divi{}
			sendToAddress = divi.Divi{}
		case models.PTDogeCash:
			coinName = dogecash.DogeCash{}
			daemonRunning = dogecash.DogeCash{}
			walletSecurityState = dogecash.DogeCash{}
			walletUnlock = dogecash.DogeCash{}
			walletValidateAddress = dogecash.DogeCash{}
			sendToAddress = dogecash.DogeCash{}
		case models.PTFeathercoin:
			coinName = ftc.Feathercoin{}
			daemonRunning = ftc.Feathercoin{}
			walletSecurityState = ftc.Feathercoin{}
			walletUnlock = ftc.Feathercoin{}
			walletValidateAddress = ftc.Feathercoin{}
			sendToAddress = ftc.Feathercoin{}
		case models.PTGroestlcoin:
		case models.PTLitecoin:
			coinName = ltc.Litecoin{}
			daemonRunning = ltc.Litecoin{}
			walletSecurityState = ltc.Litecoin{}
			walletUnlock = ltc.Litecoin{}
			walletValidateAddress = ltc.Litecoin{}
			sendToAddress = ltc.Litecoin{}
		case models.PTPhore:
		case models.PTPeercoin:
			coinName = ppc.Peercoin{}
			daemonRunning = ppc.Peercoin{}
			walletSecurityState = ppc.Peercoin{}
			walletUnlock = ppc.Peercoin{}
			walletValidateAddress = ppc.Peercoin{}
			sendToAddress = ppc.Peercoin{}
		case models.PTPIVX:
			coinName = pivx.PIVX{}
			daemonRunning = pivx.PIVX{}
			walletSecurityState = pivx.PIVX{}
			walletUnlock = pivx.PIVX{}
			walletValidateAddress = pivx.PIVX{}
			sendToAddress = pivx.PIVX{}
		case models.PTRapids:
		case models.PTReddCoin:
			coinName = rdd.ReddCoin{}
			daemonRunning = rdd.ReddCoin{}
			walletSecurityState = rdd.ReddCoin{}
			walletUnlock = rdd.ReddCoin{}
			walletValidateAddress = rdd.ReddCoin{}
			sendToAddress = rdd.ReddCoin{}
		case models.PTScala:
		case models.PTSpiderByte:
			coinName = sbyte.SpiderByte{}
			daemonRunning = sbyte.SpiderByte{}
			walletSecurityState = sbyte.SpiderByte{}
			walletUnlock = sbyte.SpiderByte{}
			walletValidateAddress = sbyte.SpiderByte{}
			sendToAddress = sbyte.SpiderByte{}
		case models.PTTrezarcoin:
			coinName = tzc.Trezarcoin{}
			daemonRunning = tzc.Trezarcoin{}
			walletSecurityState = tzc.Trezarcoin{}
			walletUnlock = tzc.Trezarcoin{}
			walletValidateAddress = tzc.Trezarcoin{}
			sendToAddress = tzc.Trezarcoin{}
		case models.PTVertcoin:
		default:
			log.Fatal("unable to determine ProjectType")
		}

		var coinAuth models.CoinAuth
		coinAuth.RPCUser = confDB.RPCuser
		coinAuth.RPCPassword = confDB.RPCpassword
		coinAuth.IPAddress = confDB.ServerIP
		coinAuth.Port = confDB.Port

		// Check to see if we are running the coin daemon locally, and if we are, make sure it's actually running
		// before attempting to connect to it.
		if coinAuth.IPAddress == "127.0.0.1" {
			bCDRunning, err := daemonRunning.DaemonRunning()
			if err != nil {
				log.Fatal("Unable to determine if coin daemon is running: " + err.Error())
			}
			if !bCDRunning {
				log.Fatal("Unable to communicate with the " + coinName.CoinName() + " server. Please make sure the " + coinName.CoinName() + " server is running, by running:\n\n" +
					appFileName + " start\n\n")
			}
		}

		// Then ask for the amount they want to send.
		var amount float32
		promptAmount := &survey.Input{
			Message: "How much " + coinName.CoinNameAbbrev() + " would you like to send?",
		}
		_ = survey.AskOne(promptAmount, &amount)

		// Then ask for the address
		address := ""
		promptAddress := &survey.Input{
			Message: "Which " + coinName.CoinName() + " address would you like to send to?",
		}
		_ = survey.AskOne(promptAddress, &address)

		// Validate address as best we can...
		// DIVI, length is 34 and starts with a D as an example...
		av := walletValidateAddress.ValidateAddress(address)
		if !av {
			log.Fatalf("It looks like the address that you are sending to is not a " + coinName.CoinName() + " address?\n\n" +
				"Please check and try again.")
		}

		// Then ask for confirmation
		send := false
		promptConfirm := &survey.Confirm{
			Message: "Are you sure?\n\nSend: " + fmt.Sprintf("%v", amount) + "\n\nTo " + coinName.CoinName() + " address: " + address + "\n\n",
		}
		_ = survey.AskOne(promptConfirm, &send)

		// Check that their wallet is unlocked

		wst, err := walletSecurityState.WalletSecurityState(&coinAuth)
		if err != nil {
			log.Fatal("Unable to determine Wallet Security State: " + err.Error())
		}
		if wst == models.WETLocked || wst == models.WETUnlockedForStaking {
			wep := coins.GetWalletEncryptionPassword()
			err := walletUnlock.WalletUnlock(&coinAuth, wep)
			if err != nil {
				log.Fatalf("failed to unlock wallet %s\n", err)
			}
		}

		time.Sleep(1 * time.Second)
		// Then send...
		if send {
			if r, err := sendToAddress.SendToAddress(&coinAuth, address, amount); err != nil {
				log.Fatalf("unable to send: %v", err)
			} else {
				fmt.Printf("Payment sent\n\n")
				fmt.Println("txid: " + r.Result)
			}
		}
	},
}

func init() {
	rootCmd.AddCommand(sendCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// sendCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// sendCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
