/*
Copyright © 2020 NAME HERE <EMAIL ADDRESS>

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
	"github.com/AlecAivazis/survey/v2"
	"log"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	//_ "github.com/AlecAivazis/survey/v2"
	"github.com/spf13/cobra"
)

// coinCmd represents the coin command
var coinCmd = &cobra.Command{
	Use:   "coin",
	Short: "The coin command is used to specify which coin you wish to work with",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		//fmt.Println("coin called")
		coin := ""
		prompt := &survey.Select{
			Message: "Please choose your preferred coin:",
			Options: []string{be.CCoinNameDivi, be.CCoinNamePhore},
		}
		survey.AskOne(prompt, &coin)
		cliConf := be.ConfStruct{}

		switch coin {
		case be.CCoinNameDivi:
			cliConf.ProjectType = be.PTDivi
			cliConf.Port = be.CDiviRPCPort
			cliConf.ServerIP = "127.0.0.1"
		case be.CCoinNamePhore:
			cliConf.ProjectType = be.PTPhore
			cliConf.Port = be.CPhoreRPCPort
			cliConf.ServerIP = "127.0.0.1"
		case be.CCoinNamePIVX:
			cliConf.ProjectType = be.PTPIVX
			cliConf.Port = be.CPIVXRPCPort
			cliConf.ServerIP = "127.0.0.1"
		case be.CCoinNameTrezarcoin:
			cliConf.ProjectType = be.PTTrezarcoin
			cliConf.Port = be.CTrezarcoinRPCPort
			cliConf.ServerIP = "127.0.0.1"
		default:
			log.Fatal("Unable to determine coin choice")
		}
		if err := be.SetConfigStruct("", cliConf); err != nil {
			log.Fatal("Unable to write to config file: ", err)
		}
		sCoinName, err := be.GetCoinName(be.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinName " + err.Error())
		}

		rpcu, rpcpw, err := be.PopulateDaemonConfFile()
		if err != nil {
			log.Fatal(err)
		}
		// because it's possible that the conf file for this coin has already been created, we need to store the returned user and password
		// so, effectively, will either be storing the existing info, or the freshly generated info
		cliConf.RPCuser = rpcu
		cliConf.RPCpassword = rpcpw
		err = be.SetConfigStruct("", cliConf)
		if err != nil {
			log.Fatal(err)
		}

		b, err := be.AllProjectBinaryFilesExists()
		if !b {
			if err := doRequiredFiles(); err != nil {
				log.Fatal(err)
			}
			fmt.Println("The " + sCoinName + " CLI bin files haven't been installed yet. Please run ./" + be.CAppFilename + " install to install them.")
		} else {
			fmt.Println("The " + sCoinName + " CLI bin files have already been installed.")
		}
	},
}

func init() {
	rootCmd.AddCommand(coinCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// coinCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// coinCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}
