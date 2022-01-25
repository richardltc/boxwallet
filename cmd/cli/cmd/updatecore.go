package cmd

import (
	"fmt"
	"github.com/AlecAivazis/survey/v2"
	"log"
	"os"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"
	divi "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/conf"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"

	"github.com/spf13/cobra"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
)

// updatecoreCmd represents the updatecore command
var updatecoreCmd = &cobra.Command{
	Use:   "updatecore",
	Short: "updates the selected coins core files",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		var app app.App
		var buCoreFiles coins.BackupCoreFiles
		var coin coins.Coin
		var coinDaemon coins.CoinDaemon
		var coinName coins.CoinName
		var conf conf.Conf
		var rmCoreFiles coins.RemoveCoreFiles

		fmt.Println("  ____          __          __   _ _      _   \n |  _ \\         \\ \\        / /  | | |    | |  \n | |_) | _____  _\\ \\  /\\  / /_ _| | | ___| |_ \n |  _ < / _ \\ \\/ /\\ \\/  \\/ / _` | | |/ _ \\ __|\n | |_) | (_) >  <  \\  /\\  / (_| | | |  __/ |_ \n |____/ \\___/_/\\_\\  \\/  \\/ \\__,_|_|_|\\___|\\__| v" + app.Version() + "\n                                              \n                                               ")

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

		// Now load our config file to see what coin choice the user has made...
		confDB, err := conf.GetConfig(true)
		if err != nil {
			log.Fatal("Unable to determine coin type. Please run " + appFileName + " coin: " + err.Error())
		}

		switch confDB.ProjectType {
		case models.PTDivi:
			buCoreFiles = divi.Divi{}
			coin = divi.Divi{}
			coinDaemon = divi.Divi{}
			coinName = divi.Divi{}
			rmCoreFiles = divi.Divi{}
		default:
			log.Fatal("Unable to determine ProjectType")
		}

		// Confirm that they wish to update t coin's files, and display what version they will be upgrading to.
		ans := true
		prompt := &survey.Confirm{
			Message: "\nAre you sure. Update the " + coinName.CoinName() + " core wallet files?:",
			Default: true,
		}
		_ = survey.AskOne(prompt, &ans)
		if ans {
			isRunning, err := coinDaemon.DaemonRunning()
			if err != nil {
				log.Fatal("Unable to tell if " + coinDaemon.DaemonFilename() + " is running")
			}
			if isRunning {
				log.Fatal("The " + coinDaemon.DaemonFilename() + " is running. Please run \"./boxwallet stop\" first")
			}

			fmt.Println("Backing up existing coin files...")
			// Backup existing coin files that are in the ~/.boxwallet dir
			if err := buCoreFiles.BackupCoreFiles(appHomeDir); err != nil {
				log.Fatal("Unable to backup core files: " + err.Error())
			}

			// Remove existing coin files now that they're backed up...
			fmt.Println("Removing existing coin files...")
			// Backup existing coin files that are in the ~/.boxwallet dir
			if err := rmCoreFiles.RemoveCoreFiles(appHomeDir); err != nil {
				log.Fatal("Unable to remove existing core file: " + err.Error())
			}

			// Download new files and install as per the coin command.
			if err := coin.DownloadCoin(appHomeDir); err != nil {
				log.Fatal("Unable to download core file: " + err.Error())
			}
			if err := coin.Install(appHomeDir); err != nil {
				log.Fatal("Unable to install core file: " + err.Error())
			}

		} else {
			// They didn't want to...
			log.Fatal("User cancelled command")
		}
		fmt.Println("\nAll done!")
	},
}

func init() {
	rootCmd.AddCommand(updatecoreCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// updatecoreCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// updatecoreCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
