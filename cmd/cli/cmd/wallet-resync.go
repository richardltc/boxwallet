package cmd

import (
	"fmt"
	"log"
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/dogecash"
	grs "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/groestlcoin"
	ltc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/litecoin"
	ppc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/peercoin"
	pivx "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/pivx"
	rpd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/rapids"
	rdd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/reddcoin"
	sbyte "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/spiderbyte"
	tzc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/trezarcoin"

	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	xbc "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/bitcoinplus"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/wallet"

	"github.com/AlecAivazis/survey/v2"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"

	"github.com/spf13/cobra"
)

// resyncCmd represents the resync command
var resyncCmd = &cobra.Command{
	Use:   "resync",
	Short: "Performs a resync of the complete blockchain",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App
		var conf conf.Conf

		appHomeDir, err := app.HomeFolder()
		if err != nil {
			log.Fatal("Unable to get HomeFolder: " + err.Error())
		}

		conf.Bootstrap(appHomeDir)
		confDB, err := conf.GetConfig(false)

		var coinName coins.CoinName
		var wallet wallet.Wallet

		switch confDB.ProjectType {
		case models.PTBitcoinPlus:
			coinName = xbc.XBC{}
			wallet = xbc.XBC{}
		case models.PTDivi:
			coinName = divi.Divi{}
			wallet = divi.Divi{}
		case models.PTDogeCash:
			coinName = dogecash.DogeCash{}
			wallet = dogecash.DogeCash{}
		case models.PTGroestlcoin:
			coinName = grs.Groestlcoin{}
			wallet = grs.Groestlcoin{}
		case models.PTLitecoin:
			coinName = ltc.Litecoin{}
			wallet = ltc.Litecoin{}
		case models.PTPeercoin:
			coinName = ppc.Peercoin{}
			wallet = ppc.Peercoin{}
		case models.PTPIVX:
			coinName = pivx.PIVX{}
			wallet = pivx.PIVX{}
		case models.PTRapids:
			coinName = rpd.Rapids{}
			wallet = rpd.Rapids{}
		case models.PTReddCoin:
			coinName = rdd.ReddCoin{}
			wallet = rdd.ReddCoin{}
		case models.PTSpiderByte:
			coinName = sbyte.SpiderByte{}
			wallet = sbyte.SpiderByte{}
		case models.PTTrezarcoin:
			coinName = tzc.Trezarcoin{}
			wallet = tzc.Trezarcoin{}
		default:
			log.Fatal("Unable to determine ProjectType")
		}

		b, err := wallet.DaemonRunning()
		if err != nil {
			log.Fatal("Unable to determine if Daemon is running " + err.Error())
		}
		if b {
			log.Fatal("Please stop the daemon first, before performing a resync")
		}

		ans := false
		prompt := &survey.Confirm{
			Message: `Are you sure? Perform a resync on your ` + coinName.CoinName() + ` wallet?:`,
		}
		if err := survey.AskOne(prompt, &ans); err != nil {
			log.Fatal("Error using survey: " + err.Error())
		}
		if !ans {
			log.Fatal("resync not attempted.")
		}

		// Now, before performing a resync, see if we can download a snapshot to speed things up.
		coinSupportsBCSnapshot := false
		var coinBC coins.CoinBlockchain
		var coinRemoveBCD coins.RemoveBlockchainData
		switch confDB.ProjectType {
		case models.PTDenarius:
			//coinSupportsBCSnapshot = true
			//coinBC = denarius.Denarius{}
		case models.PTDivi:
			coinSupportsBCSnapshot = true
			coinBC = divi.Divi{}
			coinRemoveBCD = divi.Divi{}
		case models.PTReddCoin:
			//coinSupportsBCSnapshot = true
			//coinBC = rdd.ReddCoin{}
		}
		resyncStillRequired := true
		if coinSupportsBCSnapshot {
			// Ask if the user wants to download the snapshot to speed up the resync.
			// If they do, download it, if not, just perform a resync.

			ans := true
			prompt := &survey.Confirm{
				Message: "\nWould you like to download the Blockchain snapshot, to speed up the resync process?:",
				Default: true,
			}
			_ = survey.AskOne(prompt, &ans)
			if ans {
				fmt.Println("Removing existing Blockchain data...")
				if err := coinRemoveBCD.RemoveBlockchainData(); err != nil {
					log.Fatal("Unable to remove existing Blockchain data: " + err.Error())
				}
				fmt.Println("Downloading blockchain snapshot...")
				if err := coinBC.DownloadBlockchain(); err != nil {
					log.Fatal("Unable to download blockchain snapshot: " + err.Error())
				}
				fmt.Println("Unarchiving blockchain snapshot...")
				if err := coinBC.UnarchiveBlockchainSnapshot(); err != nil {
					log.Fatal("Unable to unarchive blockchain snapshot: " + err.Error())
				}

				resyncStillRequired = false
			} else {
				resyncStillRequired = true
			}
		}

		if resyncStillRequired {
			if err := wallet.WalletResync(appHomeDir); err != nil {
				log.Fatal("Unable to perform resync: " + err.Error())
			}
			fmt.Println("Your " + coinName.CoinName() + " wallet is now syncing again. Please use ./boxwallet dash to view")
		} else {
			// All is done, but the user needs to start the Daemon again
			fmt.Println("Your " + coinName.CoinName() + " wallet has now been re-synced. Please use ./boxwallet start and ./boxwallet dash to view")
		}

	},
}

func init() {
	walletCmd.AddCommand(resyncCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// resyncCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// resyncCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
