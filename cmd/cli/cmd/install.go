/*
Package cmd ...
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
	"errors"
	"fmt"
	"path/filepath"

	// gwc "github.com/richardltc/gwcommon"
	"github.com/spf13/cobra"
	"log"
	"os"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
)

const ()

// installCmd represents the install command
var installCmd = &cobra.Command{
	Use:   "install",
	Short: "Downloads, installs, configures and creates a new wallet, for the coin of your choosing",
	Long: `Downloads the latest official binary files for the coin of your choosing,

You can then view the ` + be.CAppName + ` dashboard by running the command: ` + be.CAppFilename + ` dash`,
	Run: func(cmd *cobra.Command, args []string) {
		log.Fatal("The install command is no longer required or supported. Use the coin command instead.") //err.Error())

		// Lets load our config file first, to see if the user has made their coin choice...
		cliConf, err := be.GetConfigStruct("", true)
		if err != nil {
			log.Fatal("Unable to determine coin type. Please run './" + be.CAppFilename + " coin'") //err.Error())
			//log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		}

		// Before we do anything, make sure we have all of the required Wallet files in our directory
		//sAppName, err := be.GetAppName(gwc.APPTCLI)
		//if err != nil {
		//	log.Fatal("Unable to GetAppName " + err.Error())
		//}
		sCoinDaemonName, err := be.GetCoinDaemonFilename(be.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinDaemonFilename " + err.Error())
		}
		sCoinName, err := be.GetCoinName(be.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinName " + err.Error())
		}
		//sAppCLIName, err := be.GetAppCLIName()
		//if err != nil {
		//	log.Fatal("Unable to GetAppCLIName " + err.Error())
		//}
		//sLogfileName, err := gwc.GetAppLogfileName()
		//if err != nil {
		//	log.Fatal("Unable to GetAppLogfileName " + err.Error())
		//}
		sAppFileCLIName, err := be.GetAppFileName()
		if err != nil {
			log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		}

		ex, err := os.Executable()
		if err != nil {
			log.Fatal("Unable to retrieve running binary: %v ", err)
		}
		abf := be.AddTrailingSlash(filepath.Dir(ex))

		//chf, err := be.GetCoinHomeFolder(be.APPTCLI)
		//if err != nil {
		//	log.Fatal("Unable to GetCoinHomeFolder " + err.Error())
		//}

		// Check for the App Config file. This should have already been created by the "coin" command
		if !be.FileExists("./" + be.CConfFile + be.CConfFileExt) {
			log.Fatal("Unable to find the file " + be.CConfFile)
		}

		lfp := abf + be.CAppLogfile

		// Now let's make sure that we have our apps bin folder...
		if _, err := os.Stat(abf); os.IsNotExist(err) {

			// the /home/user/.divi/ bin folder does not exist, so lets create it
			log.Print(abf + " not found, so creating...")
			if err := os.Mkdir(abf, 0700); err != nil {
				log.Fatal(err)
			}
			if err := be.AddToLog(lfp, abf+" folder created"); err != nil {
				log.Fatal(err)
			}
		}

		if err := be.AddToLog(lfp, be.CAppName+" "+be.CBWAppVersion+" Starting..."); err != nil {
			log.Fatal(err)
		}

		if err := be.AddToLog(lfp, "Installing "+sCoinName+" and "+be.CAppName+" bin files..."); err != nil {
			log.Fatal(err)
		}

		// I think this can be done within the "coin" command, so I'm going to move it there...
		// Now populate the coin daemon conf file, if required, and store the rpc username and password into the cli conf file
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
			if err := be.AddToLog(lfp, "The "+sCoinName+" CLI bin files have been installed in "+abf); err != nil {
				log.Fatal(err)
			}
		} else {
			if err := be.AddToLog(lfp, "The "+sCoinName+" CLI bin files already exist in "+abf); err != nil {
				log.Fatal(err)
			}
		}

		// Add path to bash
		// err = gwc.AddProjectPath()
		// if err != nil {
		// 	log.Fatal(err)
		// }

		fmt.Println("\n\n" + be.CAppName + " has now been successfully installed")
		fmt.Println("\n\nTo run " + be.CAppName + ", please first make sure that the " + sCoinDaemonName + " daemon is running, by running:\n\n")
		fmt.Println(abf + sAppFileCLIName + " start\n\n")
		fmt.Println("With " + sCoinDaemonName + " now running, you should now be able to view the dashboard by running:\n\n")
		fmt.Println(abf + sAppFileCLIName + " dash\n\n" +
			be.CAppName + " is free to use, however, any " + sCoinName + " donations would be most welcome via the " + sCoinName + " address below:\n\n")

		switch cliConf.ProjectType {
		case be.PTDivi:
			fmt.Println("DSniZmeSr62wiQXzooWk7XN4wospZdqePt")
		case be.PTPhore:
			fmt.Println("\n\nPKFcy7UTEWegnAq7Wci8Aj76bQyHMottF8")
		case be.PTPIVX:
			fmt.Println("\n\nDFHmj4dExVC24eWoRKmQJDx57r4svGVs3J")
		case be.PTTrezarcoin:
			fmt.Println("\n\nTnkHScr6iTcfK11GDPFjNgJ7V3GZtHEy9V")
		default:
			err = errors.New("unable to determine ProjectType")
		}

		fmt.Println("\n\nThank you for using " + be.CAppName)
		fmt.Println("\n\n")
	},
}

func init() {
	rootCmd.AddCommand(installCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// installCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// installCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}

// getCoinDownloadLink - Returns a link to the required file
func getCoinDownloadLink(ostype be.OSType) (url, file string, err error) {
	bwconf, err := be.GetConfigStruct("", true)
	if err != nil {
		return "", "", err
	}
	switch bwconf.ProjectType {
	case be.PTDivi:
		switch ostype {
		case be.OSTArm:
			return be.CDownloadURLDivi, be.CDFDiviRPi, nil
		case be.OSTLinux:
			return be.CDownloadURLDivi, be.CDFDiviLinux, nil
		case be.OSTWindows:
			return be.CDownloadURLDivi, be.CDFDiviWindows, nil
		default:
			err = errors.New("unable to determine OSType")
		}
	case be.PTPhore:
		switch ostype {
		case be.OSTArm:
			return be.CDownloadURLPhore, be.CDFPhoreRPi, nil
		case be.OSTLinux:
			return be.CDownloadURLPhore, be.CDFPhoreLinux, nil
		case be.OSTWindows:
			return be.CDownloadURLPhore, be.CDFPhoreWindows, nil
		default:
			err = errors.New("unable to determine OSType")
		}
	case be.PTPIVX:
		switch ostype {
		case be.OSTArm:
			return be.CDownloadURLPIVX, be.CDFPIVXFileRPi, nil
		case be.OSTLinux:
			return be.CDownloadURLPIVX, be.CDFPIVXFileLinux, nil
		case be.OSTWindows:
			return be.CDownloadURLPIVX, be.CDFPIVXFileWindows, nil
		default:
			err = errors.New("unable to determine OSType")
		}
	case be.PTTrezarcoin:
		switch ostype {
		case be.OSTArm:
			return be.CDownloadURLTC, be.CDFTrezarcoinRPi, nil
		case be.OSTLinux:
			return be.CDownloadURLTC, be.CDFTrezarcoinLinux, nil
		case be.OSTWindows:
			return be.CDownloadURLTC, be.CDFTrezarcoinWindows, nil
		default:
			err = errors.New("unable to determine OSType")
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}
	return "", "", nil
}
