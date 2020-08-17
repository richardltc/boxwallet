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
	gwc "github.com/richardltc/gwcommon"
	"github.com/spf13/cobra"
	"log"
	"os"
	be "richardmace.co.uk/boxdivi/cmd/cli/cmd/bend"
	"runtime"
)

const (
	//cDownloadURLDivi string = "https://github.com/DiviProject/Divi/releases/download/v1.0.8/"
	cDownloadURLDivi string = "https://github.com/DiviProject/Divi/releases/download/v1.1.2/"
	cDownloadURLPIVX string = "https://github.com/PIVX-Project/PIVX/releases/download/v4.1.0/"
	cDownloadURLTC   string = "https://github.com/TrezarCoin/TrezarCoin/releases/download/2.0.1.0/"

	// Divi public download files
	//cDFDiviRPi     string = "divi-1.0.8-RPi2.tar.gz"
	//cDFDiviLinux   string = "divi-1.0.8-x86_64-linux-gnu.tar.gz"
	//cDFDiviWindows string = "divi-1.0.8-win64.zip"
	cDFDiviRPi     string = "divi-1.1.2-RPi2.tar.gz"
	cDFDiviLinux   string = "divi-1.1.2-x86_64-linux-gnu.tar.gz"
	cDFDiviWindows string = "divi-1.1.2-win64.zip"

	cDiviExtractedDir string = "divi-1.1.2/"
	//cDiviExtractedDir string = "divi-1.0.8/"

	// PIVX public download files
	cDFPIVXFileRPi     string = "pivx-4.1.0-aarch64-linux-gnu.tar.gz"
	cDFPIVXFileLinux   string = "pivx-4.1.0-x86_64-linux-gnu.tar.gz"
	cDFPIVXFileWindows string = "pivx-4.1.0-win64.zip"

	cPIVXExtractedDirArm     string = "pivx-4.1.0-aarch64-linux-gnu/"
	cPIVXExtractedDirLinux   string = "pivx-4.1.0-x86_64-linux-gnu/"
	cPIVXExtractedDirWindows string = "pivx-4.1.0-win64\\"

	// Trezarcoin public download files
	cDFTrezarcoinRPi     string = "trezarcoin-2.0.1-rPI.zip"
	cDFTrezarcoinLinux   string = "trezarcoin-2.0.1-linux64.tar.gz"
	cDFTrezarcoinWindows string = "trezarcoin-2.0.1-win64-setup.exe"
)

// installCmd represents the install command
var installCmd = &cobra.Command{
	Use:   "install",
	Short: "Downloads, installs, configures and creates a new " + sCoinName + " wallet",
	Long: `Downloads the latest official ` + sCoinName + ` binaries and installs them in a directory called ` + sAppBinFolder + `,
and runs ` + sCoinDName + ` to sync the block chain. 

You can then view the ` + sAppName + ` dashboard by running the command: ` + sAppCLIFilename + ` dash`,
	Run: func(cmd *cobra.Command, args []string) {
		cliConf, err := gwc.GetCLIConfStruct()
		if err != nil {
			log.Fatal("Unable to GetCLIConfStruct " + err.Error())
		}

		// Before we do anything, make sure we have all of the required Wallet files in our directory
		sAppName, err := gwc.GetAppName(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetAppName " + err.Error())
		}
		sCoinDaemonName, err := gwc.GetCoinDaemonFilename(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinDaemonFilename " + err.Error())
		}
		sCoinName, err := gwc.GetCoinName(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinName " + err.Error())
		}
		sAppCLIName, err := gwc.GetAppCLIName(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetAppCLIName " + err.Error())
		}
		sLogfileName, err := gwc.GetAppLogfileName()
		if err != nil {
			log.Fatal("Unable to GetAppLogfileName " + err.Error())
		}
		sAppFileCLIName, err := gwc.GetAppFileName(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetAppFileCLIName " + err.Error())
		}
		sAppFileUpdaterName, err := gwc.GetAppFileName(gwc.APPTUpdater)
		if err != nil {
			log.Fatal("Unable to GetAppFileName " + err.Error())
		}
		abf, err := gwc.GetAppsBinFolder(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetAppsBinFolder " + err.Error())
		}
		chf, err := gwc.GetCoinHomeFolder(gwc.APPTCLI)
		if err != nil {
			log.Fatal("Unable to GetCoinHomeFolder " + err.Error())
		}

		// Check for the App Config file
		if !gwc.FileExists("./" + gwc.CCLIConfFile + gwc.CCLIConfFileExt) {
			log.Fatal("Unable to find the file " + gwc.CCLIConfFile)
		}

		// // Check for the App Server
		// if !gwc.FileExists("./" + sAppFileServerName) {
		// 	log.Fatal("Unable to find the file " + sAppFileServerName)
		// }

		// Check for Godivi Updater
		// Check for the App Server
		if !gwc.FileExists("./" + sAppFileUpdaterName) {
			log.Fatal("Unable to find the file " + sAppFileUpdaterName)
		}

		lfp := abf + sLogfileName
		// 	// Check to make sure we have enough memory
		// 	trkb := sysinfo.Get().TotalRam
		// 	trmb := int(trkb) / 1024

		// 	gwc.AddToLog(lfp, "Detected total memory of: "+strconv.Itoa(trmb)+"MB")
		// 	if trmb < gwc.CMinRequiredMemoryMB {
		// 		gwc.AddToLog(lfp, "The amoount of memory you have for running a "+sCoinName+" wallet is too low, so checking swap...")
		// 		// The total ram is less than the minimum required, so lets make sure adequate swap is in place
		// 		ts := int(sysinfo.Get().TotalSwap) / 1024
		// 		if ts < gwc.CMinRequiredSwapMB {
		// 			gwc.AddToLog(lfp, "Detected swap total of: "+strconv.Itoa(ts)+"MB")
		// 			gwc.AddToLog(lfp, "The amoount of swap you have for running a "+sCoinName+" wallet is to low, so we need to increase swap useage...\n\n")
		// 			gwc.AddToLog(lfp, `Please follow the following notes to add 2GB of swap:

		// Step 1

		// # sudo fallocate -l 2G /swapfile
		// # sudo chmod 600 /swapfile
		// # sudo mkswap /swapfile
		// # sudo swapon /swapfile

		// Step 2

		// # sudo nano /etc/fstab

		// ...and then add the line below:

		// /swapfile swap swap defaults 0 0
		// `)
		// 			os.Exit(0)
		// 		}
		// 	}

		// Now let's make sure that we have our divi bin folder

		if _, err := os.Stat(abf); !os.IsNotExist(err) {
			// /home/user/boxdivi/ bin folder already exists, so lets stop
			log.Fatal("It looks like you have already installed the " + sCoinName + " binaries in the folder " + abf)
		} else {
			// the /home/user/.divi/ bin folder does not exist, so lets create it
			log.Print(abf + " not found, so creating...")
			if err := os.Mkdir(abf, 0700); err != nil {
				log.Fatal(err)
			}
			if err := gwc.AddToLog(lfp, abf+" folder created"); err != nil {
				log.Fatal(err)
			}
		}

		if err := gwc.AddToLog(lfp, sAppCLIName+" "+gwc.CAppVersion+" Starting..."); err != nil {
			log.Fatal(err)
		}

		if err := gwc.AddToLog(lfp, "Installing "+sCoinName+" and "+sAppName+" bin files..."); err != nil {
			log.Fatal(err)
		}

		if _, err = os.Stat(chf); !os.IsNotExist(err) {
			// The coin home folder exists, so lets stop now
			s := "It looks like you already have a " + sCoinName + " wallet installed in the folder " + chf
			if err := gwc.AddToLog(lfp, s); err != nil {
				log.Fatal(err)
			}
			log.Fatal(s)
		}

		// Now populate the coin daemon conf file, and store the rpc username and password into the cli conf file
		rpcu, rpcpw, err := be.PopulateDaemonConfFile()
		if err != nil {
			log.Fatal(err)
		}
		cliConf.RPCuser = rpcu
		cliConf.RPCpassword = rpcpw
		err = gwc.SetCLIConfStruct(cliConf)
		if err != nil {
			log.Fatal(err)
		}

		//gwc.AddToLog(lfp, "Getting required files")
		if err := doRequiredFiles(); err != nil {
			log.Fatal(err)
		}

		if err := gwc.AddToLog(lfp, "The "+sCoinName+" CLI bin files have been installed in "+abf); err != nil {
			log.Fatal(err)
		}

		// Add path to bash
		// err = gwc.AddProjectPath()
		// if err != nil {
		// 	log.Fatal(err)
		// }

		fmt.Println("\n\n" + sAppCLIName + " has now been successfully installed\n\n")
		fmt.Println("To run " + sAppCLIName + ", please first make sure that the " + sCoinDaemonName + " daemon is running, by running:\n\n")
		fmt.Println(abf + sAppFileCLIName + " start\n\n")
		fmt.Println("With " + sCoinDaemonName + " now running, you should now be able to view the dashboard by running:\n\n")
		fmt.Println(abf + sAppFileCLIName + " dash\n\n" +
			sAppName + " is free to use, however, any donations would be most welcome via the address below:\n\n")
		fmt.Println("DSniZmeSr62wiQXzooWk7XN4wospZdqePt\n\n")
		fmt.Println("Thank you for using " + sAppName + "\n\n")
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
	abf, err := gwc.GetAppsBinFolder(gwc.APPTCLI)
	if err != nil {
		return fmt.Errorf("Unable to perform GetAppsBinFolder: %v ", err)
	}

	gwconf, err := gwc.GetCLIConfStruct()
	if err != nil {
		return fmt.Errorf("Unable to get CLIConfigStruct: %v ", err)
	}
	switch gwconf.ProjectType {
	case gwc.PTDivi:
		if runtime.GOOS == "windows" {
			filePath = abf + cDFDiviWindows
			fileURL = cDownloadURLDivi + cDFDiviWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + cDFDiviRPi
			fileURL = cDownloadURLDivi + cDFDiviRPi
		} else {
			filePath = abf + cDFDiviLinux
			fileURL = cDownloadURLDivi + cDFDiviLinux
		}
	case gwc.PTPIVX:
		if runtime.GOOS == "windows" {
			filePath = abf + cDFPIVXFileWindows
			fileURL = cDownloadURLPIVX + cDFPIVXFileWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + cDFPIVXFileRPi
			fileURL = cDownloadURLPIVX + cDFPIVXFileRPi
		} else {
			filePath = abf + cDFPIVXFileLinux
			fileURL = cDownloadURLPIVX + cDFPIVXFileLinux
		}
	case gwc.PTTrezarcoin:
		if runtime.GOOS == "windows" {
			filePath = abf + cDFTrezarcoinWindows
			fileURL = cDownloadURLTC + cDFTrezarcoinWindows
		} else if runtime.GOARCH == "arm" {
			filePath = abf + cDFTrezarcoinRPi
			fileURL = cDownloadURLTC + cDFTrezarcoinRPi
		} else {
			filePath = abf + cDFTrezarcoinLinux
			fileURL = cDownloadURLTC + cDFTrezarcoinLinux
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}
	if err != nil {
		return fmt.Errorf("error - %v", err)
	}

	log.Print("Downloading required files...")
	if err := gwc.DownloadFile(filePath, fileURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", filePath+fileURL, err)
	}
	defer gwc.FileDelete(filePath)

	r, err := os.Open(filePath)
	if err != nil {
		return fmt.Errorf("unable to open file: %v - %v", filePath, err)
	}

	// Now, decompress the files...
	log.Print("decompressing files...")
	switch gwconf.ProjectType {
	case gwc.PTDivi:
		if runtime.GOOS == "windows" {
			_, err = gwc.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = gwc.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + cDiviExtractedDir)
		} else {
			err = gwc.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + cDiviExtractedDir)
		}
	case gwc.PTPIVX:
		if runtime.GOOS == "windows" {
			_, err = gwc.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = gwc.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + cPIVXExtractedDirArm)
		} else {
			err = gwc.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
			defer os.RemoveAll("./" + cPIVXExtractedDirLinux)
		}
	case gwc.PTTrezarcoin:
		if runtime.GOOS == "windows" {
			_, err = gwc.UnZip(filePath, "tmp")
			if err != nil {
				return fmt.Errorf("unable to unzip file: %v - %v", filePath, err)
			}
			defer os.RemoveAll("tmp")
		} else if runtime.GOARCH == "arm" {
			err = gwc.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
		} else {
			err = gwc.ExtractTarGz(r)
			if err != nil {
				return fmt.Errorf("unable to extractTarGz file: %v - %v", r, err)
			}
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}

	log.Print("Installing files...")

	// Copy files to correct location
	var srcPath, srcFileCLI, srcFileD, srcFileTX, srcFileGWConfCLI /*srcFileGWConfSrv,*/, srcFileGWCLI, srcFileGWUprade /*srcFileGWServer*/ string
	srcFileGWConfCLI = gwc.CCLIConfFile + gwc.CCLIConfFileExt
	//srcFileGWConfSrv = gwc.CServerConfFile + gwc.CServerConfFileExt
	var srcREADMEFile = "README.md"

	switch gwconf.ProjectType {
	case gwc.PTDivi:
		switch runtime.GOOS {
		case "windows":
			srcPath = "./tmp/" + cDiviExtractedDir + "bin/"
			srcFileCLI = gwc.CDiviCliFileWin
			srcFileD = gwc.CDiviDFileWin
			srcFileTX = gwc.CDiviTxFileWin
			srcFileGWCLI = gwc.CAppCLIFileWinGoDivi
			// srcFileGWServer = gwc.CAppServerFileWinGoDivi
		case "arm":
			srcPath = "./" + cDiviExtractedDir + "bin/"
			srcFileCLI = gwc.CDiviCliFile
			srcFileD = gwc.CDiviDFile
			srcFileTX = gwc.CDiviTxFile
			srcFileGWCLI = gwc.CAppCLIFileGoDivi
			srcFileGWUprade = gwc.CAppUpdaterFileGoDivi
			// srcFileGWServer = gwc.CAppServerFileGoDivi
		case "linux":
			srcPath = "./" + cDiviExtractedDir + "bin/"
			srcFileCLI = gwc.CDiviCliFile
			srcFileD = gwc.CDiviDFile
			srcFileTX = gwc.CDiviTxFile
			srcFileGWCLI = gwc.CAppCLIFileGoDivi
			srcFileGWUprade = gwc.CAppUpdaterFileGoDivi
			// srcFileGWServer = gwc.CAppServerFileGoDivi
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case gwc.PTPIVX:
		switch runtime.GOOS {
		case "windows":
			srcPath = "./tmp/" + cPIVXExtractedDirWindows + "bin/"
			srcFileCLI = gwc.CPIVXCliFileWin
			srcFileD = gwc.CPIVXDFileWin
			srcFileTX = gwc.CPIVXTxFileWin
			srcFileGWCLI = gwc.CAppCLIFileWinGoPIVX
			// srcFileGWServer = gwc.CAppServerFileWinGoPIVX
		case "arm":
			srcPath = "./" + cPIVXExtractedDirArm + "bin/"
			srcFileCLI = gwc.CPIVXCliFile
			srcFileD = gwc.CPIVXDFile
			srcFileTX = gwc.CPIVXTxFile
			srcFileGWCLI = gwc.CAppCLIFileGoPIVX
			srcFileGWUprade = gwc.CAppUpdaterFileGoPIVX
			// srcFileGWServer = gwc.CAppServerFileGoPIVX
		case "linux":
			srcPath = "./" + cPIVXExtractedDirLinux + "bin/"
			srcFileCLI = gwc.CPIVXCliFile
			srcFileD = gwc.CPIVXDFile
			srcFileTX = gwc.CPIVXTxFile
			srcFileGWCLI = gwc.CAppCLIFileGoPIVX
			srcFileGWUprade = gwc.CAppUpdaterFileGoPIVX
			// srcFileGWServer = gwc.CAppServerFileGoPIVX
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}
	case gwc.PTTrezarcoin:
		switch runtime.GOOS {
		case "windows":
			err = errors.New("windows is not currently supported for Trezarcoin")
		case "arm":
			err = errors.New("arm is not currently supported for Trezarcoin")
		case "linux":
			srcPath = "./"
			srcFileCLI = gwc.CTrezarcoinCliFile
			srcFileD = gwc.CTrezarcoinDFile
			srcFileTX = gwc.CTrezarcoinTxFile
			srcFileGWCLI = gwc.CAppCLIFileGoTrezarcoin
			srcFileGWUprade = gwc.CAppUpdaterFileGoTrezarcoin
			// srcFileGWServer = gwc.CAppServerFileGoTrezarcoin
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
	err = gwc.FileCopy(srcPath+srcFileCLI, abf+srcFileCLI, false)
	if err != nil {
		return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileCLI, abf+srcFileCLI, err)
	}
	err = os.Chmod(abf+srcFileCLI, 0777)
	if err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileCLI, err)
	}
	// coind
	err = gwc.FileCopy(srcPath+srcFileD, abf+srcFileD, false)
	if err != nil {
		return fmt.Errorf("unable to copyFile: %v - %v", srcPath+srcFileD, err)
	}
	err = os.Chmod(abf+srcFileD, 0777)
	if err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileD, err)
	}

	// cointx
	err = gwc.FileCopy(srcPath+srcFileTX, abf+srcFileTX, false)
	if err != nil {
		return fmt.Errorf("unable to copyFile: %v - %v", srcPath+srcFileTX, err)
	}
	err = os.Chmod(abf+srcFileTX, 0777)
	if err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileTX, err)
	}

	// Copy the gowallet binary itself
	ex, err := os.Executable()
	if err != nil {
		return fmt.Errorf("error getting exe - %v", err)
	}

	err = gwc.FileCopy(ex, abf+srcFileGWCLI, false)
	if err != nil {
		return fmt.Errorf("unable to copyFile: %v - %v", abf+srcFileGWCLI, err)
	}
	err = os.Chmod(abf+srcFileGWCLI, 0777)
	if err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileGWCLI, err)
	}

	// Copy the README.md file
	err = gwc.FileCopy("./"+srcREADMEFile, abf+srcREADMEFile, false)
	if err != nil {
		return fmt.Errorf("unable to copyFile from: %v to %v - %v", "./"+srcREADMEFile, abf+srcREADMEFile, err)
	}

	// Copy the CLI config file
	err = gwc.FileCopy("./"+srcFileGWConfCLI, abf+srcFileGWConfCLI, false)
	if err != nil {
		return fmt.Errorf("unable to copyFile: %v - %v", abf+srcFileGWConfCLI, err)
	}

	// // Copy the Server config file
	// err = gwc.FileCopy("./"+srcFileGWConfSrv, abf+srcFileGWConfSrv, false)
	// if err != nil {
	// 	return fmt.Errorf("Unable to copyFile: %v - %v", abf+srcFileGWConfSrv, err)
	// }

	// Copy the updater file
	switch gwconf.ProjectType {
	case gwc.PTDivi:
		switch runtime.GOOS {
		case "arm":
			err = gwc.FileCopy("./"+gwc.CAppUpdaterFileGoDivi, abf+srcFileGWUprade, false)
			if err != nil {
				return fmt.Errorf("unable to copyFile: %v - %v", abf+srcFileGWUprade, err)
			}
			err = os.Chmod(abf+srcFileGWUprade, 0777)
			if err != nil {
				return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileGWUprade, err)
			}
		case "linux":
			err = gwc.FileCopy("./"+gwc.CAppUpdaterFileGoDivi, abf+srcFileGWUprade, false)
			if err != nil {
				return fmt.Errorf("unable to copyFile: %v - %v", abf+srcFileGWUprade, err)
			}
			err = os.Chmod(abf+srcFileGWUprade, 0777)
			if err != nil {
				return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileGWUprade, err)
			}
		case "windows":
			// TODO Code the Windows part
			err = gwc.FileCopy(""+gwc.CAppUpdaterFileGoDivi, abf+srcFileGWUprade, false)
			if err != nil {
				return fmt.Errorf("unable to copyFile: %v - %v", abf+srcFileGWUprade, err)
			}
			err = os.Chmod(abf+srcFileGWUprade, 0777)
			if err != nil {
				return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileGWUprade, err)
			}
		default:
			err = errors.New("unable to determine runtime.GOOS")

		}
	case gwc.PTPIVX:
		switch runtime.GOOS {
		case "arm":
			err = gwc.FileCopy("./"+gwc.CAppUpdaterFileGoPIVX, abf+srcFileGWUprade, false)
			if err != nil {
				return fmt.Errorf("unable to copyFile: %v - %v", abf+srcFileGWUprade, err)
			}
			err = os.Chmod(abf+srcFileGWUprade, 0777)
			if err != nil {
				return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileGWUprade, err)
			}
		case "linux":
			err = gwc.FileCopy("./"+gwc.CAppUpdaterFileGoPIVX, abf+srcFileGWUprade, false)
			if err != nil {
				return fmt.Errorf("unable to copyFile: %v - %v", abf+srcFileGWUprade, err)
			}
			err = os.Chmod(abf+srcFileGWUprade, 0777)
			if err != nil {
				return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileGWUprade, err)
			}
		case "windows":
			// TODO Code the Windows part
		default:
			err = errors.New("unable to determine runtime.GOOS")

		}
	case gwc.PTTrezarcoin:
		switch runtime.GOOS {
		case "arm":
			err = gwc.FileCopy("./"+gwc.CAppUpdaterFileGoTrezarcoin, abf+srcFileGWUprade, false)
			if err != nil {
				return fmt.Errorf("unable to copyFile: %v - %v", abf+srcFileGWUprade, err)
			}
			err = os.Chmod(abf+srcFileGWUprade, 0777)
			if err != nil {
				return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileGWUprade, err)
			}
		case "linux":
			err = gwc.FileCopy("./"+gwc.CAppUpdaterFileGoTrezarcoin, abf+srcFileGWUprade, false)
			if err != nil {
				return fmt.Errorf("unable to copyFile: %v - %v", abf+srcFileGWUprade, err)
			}
			err = os.Chmod(abf+srcFileGWUprade, 0777)
			if err != nil {
				return fmt.Errorf("unable to chmod file: %v - %v", abf+srcFileGWUprade, err)
			}
		case "windows":
			// TODO Code the Windows part
		default:
			err = errors.New("unable to determine runtime.GOOS")
		}

	default:
		err = errors.New("unable to determine ProjectType")
	}

	// // Copy the App Server file
	// switch gwconf.ProjectType {
	// case gwc.PTDivi:
	// 	if runtime.GOOS == "windows" {
	// 		// TODO Code the Windows part
	// 	} else if runtime.GOARCH == "arm" {
	// 		err = gwc.FileCopy("./"+gwc.CAppServerFileGoDivi, abf+srcFileGWServer, false)
	// 		if err != nil {
	// 			return fmt.Errorf("Unable to copyFile: %v - %v", abf+srcFileGWServer, err)
	// 		}
	// 		err = os.Chmod(abf+srcFileGWServer, 0777)
	// 		if err != nil {
	// 			return fmt.Errorf("Unable to chmod file: %v - %v", abf+srcFileGWServer, err)
	// 		}

	// 	} else {
	// 		err = gwc.FileCopy("./"+gwc.CAppServerFileGoDivi, abf+srcFileGWServer, false)
	// 		if err != nil {
	// 			return fmt.Errorf("Unable to copyFile: %v - %v", abf+srcFileGWServer, err)
	// 		}
	// 		err = os.Chmod(abf+srcFileGWServer, 0777)
	// 		if err != nil {
	// 			return fmt.Errorf("Unable to chmod file: %v - %v", abf+srcFileGWServer, err)
	// 		}
	// 	}
	// case gwc.PTTrezarcoin:
	// 	switch runtime.GOOS {
	// 	case "arm":
	// 		err = gwc.FileCopy("./"+gwc.CAppServerFileGoTrezarcoin, abf+srcFileGWServer, false)
	// 		if err != nil {
	// 			return fmt.Errorf("Unable to copyFile: %v - %v", abf+srcFileGWServer, err)
	// 		}
	// 		err = os.Chmod(abf+srcFileGWServer, 0777)
	// 		if err != nil {
	// 			return fmt.Errorf("Unable to chmod file: %v - %v", abf+srcFileGWServer, err)
	// 		}
	// 	case "linux":
	// 		err = gwc.FileCopy("./"+gwc.CAppServerFileGoTrezarcoin, abf+srcFileGWServer, false)
	// 		if err != nil {
	// 			return fmt.Errorf("Unable to copyFile: %v - %v", abf+srcFileGWServer, err)
	// 		}
	// 		err = os.Chmod(abf+srcFileGWServer, 0777)
	// 		if err != nil {
	// 			return fmt.Errorf("Unable to chmod file: %v - %v", abf+srcFileGWServer, err)
	// 		}
	// 	case "windows":
	// 		// TODO Code the Windows part
	// 	default:
	// 		err = errors.New("Unable to determine runtime.GOOS")
	// 	}

	// default:
	// 	err = errors.New("Unable to determine ProjectType")

	// }

	return nil
}

// getCoinDownloadLink - Returns a link to the required file
func getCoinDownloadLink(ostype gwc.OSType) (url, file string, err error) {
	gwconf, err := gwc.GetCLIConfStruct()
	if err != nil {
		return "", "", err
	}
	switch gwconf.ProjectType {
	case gwc.PTDivi:
		switch ostype {
		case gwc.OSTArm:
			return cDownloadURLDivi, cDFDiviRPi, nil
		case gwc.OSTLinux:
			return cDownloadURLDivi, cDFDiviLinux, nil
		case gwc.OSTWindows:
			return cDownloadURLDivi, cDFDiviWindows, nil
		default:
			err = errors.New("unable to determine OSType")
		}
	case gwc.PTPIVX:
		switch ostype {
		case gwc.OSTArm:
			return cDownloadURLPIVX, cDFPIVXFileRPi, nil
		case gwc.OSTLinux:
			return cDownloadURLPIVX, cDFPIVXFileLinux, nil
		case gwc.OSTWindows:
			return cDownloadURLPIVX, cDFPIVXFileWindows, nil
		default:
			err = errors.New("unable to determine OSType")
		}
	case gwc.PTTrezarcoin:
		switch ostype {
		case gwc.OSTArm:
			return cDownloadURLTC, cDFTrezarcoinRPi, nil
		case gwc.OSTLinux:
			return cDownloadURLTC, cDFTrezarcoinLinux, nil
		case gwc.OSTWindows:
			return cDownloadURLTC, cDFTrezarcoinWindows, nil
		default:
			err = errors.New("unable to determine OSType")
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}
	return "", "", nil
}
