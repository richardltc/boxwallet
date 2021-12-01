/*
Package cmd ...
Copyright © 2020 Richard Mace <richard@rocksoftware.co.uk>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package cmd

import (
	"fmt"
	"os"
	//be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/app"

	"github.com/spf13/cobra"

	homedir "github.com/mitchellh/go-homedir"
	"github.com/spf13/viper"
)

var cfgFile string

//var sAppBinFolder, _ = be.GetAppsBinFolder()

//var sAppCLIName, _ = gwc.GetAppCLIName(gwc.APPTCLI) // e.g. GoDivi CLI
//var sAppName, _ = gwc.GetAppName(gwc.APPTCLI)       // e.g. GoDivi
//var sAppUpdaterFile, _ = gwc.GetAppFileName(gwc.APPTUpdater)
//var sAppCLIFilename, _ = gwc.GetAppFileName(gwc.APPTCLI)
// var sCoinName, _ = be.GetCoinName(be.APPTCLI)
// var sCoinDName, _ = be.GetCoinDaemonFilename(be.APPTCLI)

// rootCmd represents the base command when called without any subcommands
var rootCmd = &cobra.Command{

	Use:   app.CAppFilename, //  be.CAppName, //sAppCLIFilename, //"boxwallet",
	Short: app.CAppFilename + " v" + app.CAppVersion + " is a multi-coin CLI tool that makes it very easy to setup a wallet/node with a few commands",
	Long:  ``,
	// Uncomment the following line if your bare application
	// has an action associated with it:
	//	Run: func(cmd *cobra.Command, args []string) { },
}

// Execute adds all child commands to the root command and sets flags appropriately.
// This is called by main.main(). It only needs to happen once to the rootCmd.
func Execute() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

func init() {
	cobra.OnInitialize(initConfig)

	// Here you will define your flags and configuration settings.
	// Cobra supports persistent flags, which, if defined here,
	// will be global for your application.

	rootCmd.PersistentFlags().StringVar(&cfgFile, "config", "", "config file (default is $HOME/.boxwallet.yaml)")

	// Cobra also supports local flags, which will only run
	// when this action is called directly.
	rootCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}

// initConfig reads in config file and ENV variables if set.
func initConfig() {
	if cfgFile != "" {
		// Use config file from the flag.
		viper.SetConfigFile(cfgFile)
	} else {
		// Find home directory.
		home, err := homedir.Dir()
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}

		// Search config in home directory with name ".boxwallet" (without extension).
		viper.AddConfigPath(home)
		viper.SetConfigName(".boxwallet")
	}

	viper.AutomaticEnv() // read in environment variables that match

	// If a config file is found, read it in.
	if err := viper.ReadInConfig(); err == nil {
		fmt.Println("Using config file:", viper.ConfigFileUsed())
	}
}
