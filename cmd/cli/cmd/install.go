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
	// gwc "github.com/richardltc/gwcommon"
	"github.com/spf13/cobra"
	"log"
	"os"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"runtime"
)

const ()

// installCmd represents the install command
var installCmd = &cobra.Command{
	Use:   "install",
	Short: "Downloads, installs, configures and creates a new wallet, for the coin of your choosing",
	Long: `Downloads the latest official binary files for the coin of your choosing and installs them in a directory called ` + sAppBinFolder + `,

You can then view the ` + be.CAppName + ` dashboard by running the command: ` + be.CAppFilename + ` dash`,
	Run: func(cmd *cobra.Command, args []string) {
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
		//sAppFileUpdaterName, err := gwc.GetAppFileName(gwc.APPTUpdater)
		//if err != nil {
		//	log.Fatal("Unable to GetAppFileName " + err.Error())
		//}
		abf, err := be.GetAppsBinFolder()
		if err != nil {
			log.Fatal("Unable to GetAppsBinFolder " + err.Error())
		}
		//chf, err := be.GetCoinHomeFolder(be.APPTCLI)
		//if err != nil {
		//	log.Fatal("Unable to GetCoinHomeFolder " + err.Error())
		//}

		// Check for the App Config file
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

		// Now populate the coin daemon conf file, if required, and store the rpc username and password into the cli conf file
		rpcu, rpcpw, err := be.PopulateDaemonConfFile()
		if err != nil {
			log.Fatal(err)
		}
		// If the user OR password is not blank, then save them in the conf file.
		if (rpcpw != "") || (rpcu != "") {
			cliConf.RPCuser = rpcu
			cliConf.RPCpassword = rpcpw
			err = be.SetConfigStruct("", cliConf)
			if err != nil {
				log.Fatal(err)
			}
		}

		b, err := be.AllProjectBinaryFilesExists()
		if !b {
			if err := doRequiredFiles(); err != nil {
				log.Fatal(err)
			}
		}

		if err := be.AddToLog(lfp, "The "+sCoinName+" CLI bin files have been installed in "+abf); err != nil {
			log.Fatal(err)
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
			fmt.Println("DSniZmeSr62wiQXzooWk7XN4wospZdqePt\n\n")
		case be.PTPhore:
			fmt.Println("PKFcy7UTEWegnAq7Wci8Aj76bQyHMottF8\n\n")
		case be.PTPIVX:
			fmt.Println("DFHmj4dExVC24eWoRKmQJDx57r4svGVs3J\n\n")
		case be.PTTrezarcoin:
		default:
			err = errors.New("unable to determine ProjectType")
		}

		fmt.Println("Thank you for using " + be.CAppName + "\n\n")
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

// doRequiredFiles - Download and install required files
func doRequiredFiles() error {
	var filePath, fileURL string
	abf, err := be.GetAppsBinFolder()
	if err != nil {
		return fmt.Errorf("Unable to perform GetAppsBinFolder: %v ", err)
	}

	bwconf, err := be.GetConfigStruct("", true)
	if err != nil {
		return fmt.Errorf("Unable to get CLIConfigStruct: %v ", err)
	}
	switch bwconf.ProjectType {
	case be.PTDivi:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFDiviWindows
			fileURL = be.CDownloadURLDivi + be.CDFDiviWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFDiviRPi
			fileURL = be.CDownloadURLDivi + be.CDFDiviRPi
		} else {
			filePath = abf + be.CDFDiviLinux
			fileURL = be.CDownloadURLDivi + be.CDFDiviLinux
		}
	case be.PTPhore:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFPhoreWindows
			fileURL = be.CDownloadURLPhore + be.CDFPhoreWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFPhoreRPi
			fileURL = be.CDownloadURLPhore + be.CDFPhoreRPi
		} else {
			filePath = abf + be.CDFPhoreLinux
			fileURL = be.CDownloadURLPhore + be.CDFPhoreLinux
		}
	case be.PTPIVX:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFPIVXFileWindows
			fileURL = be.CDownloadURLPIVX + be.CDFPIVXFileWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFPIVXFileRPi
			fileURL = be.CDownloadURLPIVX + be.CDFPIVXFileRPi
		} else {
			filePath = abf + be.CDFPIVXFileLinux
			fileURL = be.CDownloadURLPIVX + be.CDFPIVXFileLinux
		}
	case be.PTTrezarcoin:
		if runtime.GOOS == "windows" {
			filePath = abf + be.CDFTrezarcoinWindows
			fileURL = be.CDownloadURLTC + be.CDFTrezarcoinWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + be.CDFTrezarcoinRPi
			fileURL = be.CDownloadURLTC + be.CDFTrezarcoinRPi
		} else {
			filePath = abf + be.CDFTrezarcoinLinux
			fileURL = be.CDownloadURLTC + be.CDFTrezarcoinLinux
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}
	if err != nil {
		return fmt.Errorf("error - %v", err)
	}

	log.Print("Downloading required files...")
	if err := be.DownloadFile(filePath, fileURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", filePath+fileURL, err)
	}
	defer os.Remove(filePath)

	r, err := os.Open(filePath)
	if err != nil {
		return fmt.Errorf("unable to open file: %v - %v", filePath, err)
	}

	// Now, decompress the files...
	log.Print("decompressing files...")
	switch bwconf.ProjectType {
	case be.PTDivi:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CDiviExtractedDir)
		} else {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CDiviExtractedDir)
		}
	case be.PTPhore:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CPhoreExtractedDir)
		} else {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CPhoreExtractedDir)
		}
	case be.PTPIVX:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CPIVXExtractedDirArm)
		} else {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + be.CPIVXExtractedDirLinux)
		}
	case be.PTTrezarcoin:
		if runtime.GOOS == "windows" {
			_, err = be.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
		} else {
			err = be.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}

	log.Print("Installing files...")

	// Copy files to correct location
	var srcPath, srcFileCLI, srcFileD, srcFileTX, srcFileBWConfCLI, srcFileBWCLI string
	srcFileBWConfCLI = be.CConfFile + be.CConfFileExt
	//srcFileGWConfSrv = gwc.CServerConfFile + gwc.CServerConfFileExt
	var srcREADMEFile = "README.md"

	switch bwconf.ProjectType {
	case be.PTDivi:
		switch runtime.GOOS {
		case "windows":
			srcPath = "./tmp/" + be.CDiviExtractedDir + "bin/"
			srcFileCLI = be.CDiviCliFileWin
			srcFileD = be.CDiviDFileWin
			srcFileTX = be.CDiviTxFileWin
			srcFileBWCLI = be.CAppFilenameWin
		case "arm":
			srcPath = "./" + be.CDiviExtractedDir + "bin/"
			srcFileCLI = be.CDiviCliFile
			srcFileD = be.CDiviDFile
			srcFileTX = be.CDiviTxFile
			srcFileBWCLI = be.CAppFilename
		case "linux":
			srcPath = "./" + be.CDiviExtractedDir + "bin/"
			srcFileCLI = be.CDiviCliFile
			srcFileD = be.CDiviDFile
			srcFileTX = be.CDiviTxFile
			srcFileBWCLI = be.CAppFilename
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTPhore:
		switch runtime.GOOS {
		case "windows":
			srcPath = "./tmp/" + be.CPhoreExtractedDir + "bin/"
			srcFileCLI = be.CPhoreCliFileWin
			srcFileD = be.CPhoreDFileWin
			srcFileTX = be.CPhoreTxFileWin
			srcFileBWCLI = be.CAppFilenameWin
		case "arm":
			srcPath = "./" + be.CPhoreExtractedDir + "bin/"
			srcFileCLI = be.CPhoreCliFile
			srcFileD = be.CPhoreDFile
			srcFileTX = be.CPhoreTxFile
			srcFileBWCLI = be.CAppFilename
		case "linux":
			srcPath = "./" + be.CPhoreExtractedDir + "bin/"
			srcFileCLI = be.CPhoreCliFile
			srcFileD = be.CPhoreDFile
			srcFileTX = be.CPhoreTxFile
			srcFileBWCLI = be.CAppFilename
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTPIVX:
		switch runtime.GOOS {
		case "windows":
			srcPath = "./tmp/" + be.CPIVXExtractedDirWindows + "pivx-" + be.CPIVXCoreVersion + "bin/"
			srcFileCLI = be.CPIVXCliFileWin
			srcFileD = be.CPIVXDFileWin
			srcFileTX = be.CPIVXTxFileWin
			srcFileBWCLI = be.CAppFilenameWin
		case "arm":
			srcPath = "./" + be.CPIVXExtractedDirArm + "bin/"
			srcFileCLI = be.CPIVXCliFile
			srcFileD = be.CPIVXDFile
			srcFileTX = be.CPIVXTxFile
			srcFileBWCLI = be.CAppFilename
		case "linux":
			srcPath = "./" + be.CPIVXExtractedDirLinux + "bin/"
			srcFileCLI = be.CPIVXCliFile
			srcFileD = be.CPIVXDFile
			srcFileTX = be.CPIVXTxFile
			srcFileBWCLI = be.CAppFilename
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case be.PTTrezarcoin:
		switch runtime.GOOS {
		case "windows":
			err = errors.New("windows is not currently supported for Trezarcoin")
		case "arm":
			err = errors.New("arm is not currently supported for Trezarcoin")
		case "linux":
			srcPath = "./"
			srcFileCLI = be.CTrezarcoinCliFile
			srcFileD = be.CTrezarcoinDFile
			srcFileTX = be.CTrezarcoinTxFile
			srcFileBWCLI = be.CAppFilename
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}
	if err != nil {
		return fmt.Errorf("error: - %v", err)
	}

	// coin-cli
	err = be.FileCopy(srcPath+srcFileCLI, abf+srcFileCLI, false)
	if err != nil {
		return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileCLI, abf+srcFileCLI, err)
	}
	err = os.Chmod(abf+srcFileCLI, 0777)
	if err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileCLI, err)
	}
	// coind
	err = be.FileCopy(srcPath+srcFileD, abf+srcFileD, false)
	if err != nil {
		return fmt.Errorf("unable to copyFile: %v - %v", srcPath+srcFileD, err)
	}
	err = os.Chmod(abf+srcFileD, 0777)
	if err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileD, err)
	}

	// cointx
	err = be.FileCopy(srcPath+srcFileTX, abf+srcFileTX, false)
	if err != nil {
		return fmt.Errorf("unable to copyFile: %v - %v", srcPath+srcFileTX, err)
	}
	err = os.Chmod(abf+srcFileTX, 0777)
	if err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileTX, err)
	}

	// Copy the BoxWallet binary itself
	ex, err := os.Executable()
	if err != nil {
		return fmt.Errorf("error getting exe - %v", err)
	}

	// We're only going to attempt to copy it, because it might already be in place...
	_ = be.FileCopy(ex, abf+srcFileBWCLI, false)
	//err = be.FileCopy(ex, abf+srcFileBWCLI, false)
	//if err != nil {
	//	return fmt.Errorf("unable to copyFile: %v - %v", abf+srcFileBWCLI, err)
	//}
	err = os.Chmod(abf+srcFileBWCLI, 0777)
	if err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileBWCLI, err)
	}

	// Attempt to copy the README.md file
	_ = be.FileCopy("./"+srcREADMEFile, abf+srcREADMEFile, false)
	//if err != nil {
	//	return fmt.Errorf("unable to copyFile from: %v to %v - %v", "./"+srcREADMEFile, abf+srcREADMEFile, err)
	//}

	// Attempt to copy the CLI config file
	_ = be.FileCopy("./"+srcFileBWConfCLI, abf+srcFileBWConfCLI, false)
	//if err != nil {
	//	return fmt.Errorf("unable to copyFile: %v - %v", abf+srcFileBWConfCLI, err)
	//}

	return nil
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
