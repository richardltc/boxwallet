package bend

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"runtime"
	"strings"

	"github.com/mholt/archiver"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "Peercoin"
	cCoinNameAbbrev string = "PPC"

	cCoreVersion       string = "0.10.3"
	cDownloadFileArm32        = "peercoin-" + cCoreVersion + "-arm-linux-gnueabihf.tar.gz"
	cDownloadFileArm64        = "peercoin-" + cCoreVersion + "-aarch64-linux-gnu.tar.gz"
	cDownloadFileLin          = "peercoin-" + cCoreVersion + "-x86_64-linux-gnu.tar.gz"
	cDownloadFilemacOS        = "peercoin-" + cCoreVersion + "-osx64.tar.gz"
	//CDFFileWindowsPeercoin = "peercoin-" + CCoreVersionPeercoin + "-win64.zip"

	// Directory constants

	cExtractedDirArm string = "peercoin-" + cCoreVersion + "/"
	cExtractedDirLin string = "peercoin-" + cCoreVersion + "/"
	cExtractedDirWin string = "peercoin-" + cCoreVersion + "\\"

	cDownloadURL string = "https://github.com/peercoin/peercoin/releases/download/v" + cCoreVersion + "ppc/"

	// Peercoin Wallet Constants
	cHomeDirLin string = ".peercoin"
	cHomeDirWin string = "peercoin"

	// File constants
	cConfFile      string = "peercoin.conf"
	cCliFileLin    string = "peercoin-cli"
	cCliFileWin    string = "peercoin-cli.exe"
	cDaemonFileLin string = "peercoind"
	cDaemonFileWin string = "peercoind.exe"
	cTxFileLin     string = "peercoin-tx"
	cTxFileWin     string = "peercoin-tx.exe"

	cTipAddress string = "PPwSrpCwpyxCLZvMrYVinVdj5PZ773jkf5"

	// pivx.conf file constants.
	cRPCUser string = "peercoinrpc"
	cRPCPort string = "9902"
)

type Peercoin struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (p Peercoin) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	p.RPCUser = rpcUser
	p.RPCPassword = rpcPassword
	p.IPAddress = ip
	p.Port = port
}

func (p Peercoin) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (p Peercoin) AllBinaryFilesExist(dir string) (bool, error) {
	if runtime.GOOS == "windows" {
		if !fileutils.FileExists(dir + cCliFileWin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cDaemonFileWin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cTxFileWin) {
			return false, nil
		}
	} else {
		if !fileutils.FileExists(dir + cCliFileLin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cDaemonFileLin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cTxFileLin) {
			return false, nil
		}
	}
	return true, nil
}

//func (p Peercoin) AnyAddresses(auth *models.CoinAuth) (bool, error) {
//	addresses, err := p.ListReceivedByAddress(auth, false)
//	if err != nil {
//		return false, err
//	}
//	if len(addresses.Result) > 0 {
//		return true, nil
//	}
//	return false, nil
//}

func (p Peercoin) ConfFile() string {
	return cConfFile
}

func (p Peercoin) CoinName() string {
	return cCoinName
}

func (p Peercoin) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (p Peercoin) DaemonRunning() (bool, error) {
	var err error

	if runtime.GOOS == "windows" {
		_, _, err = coins.FindProcess(cDaemonFileWin)
	} else {
		_, _, err = coins.FindProcess(cDaemonFileLin)
	}

	if err == nil {
		return true, nil
	}
	if err.Error() == "not found" {
		return false, nil
	} else {
		return false, err
	}
}

// DownloadCoin - Downloads the Syscoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (p Peercoin) DownloadCoin(location string) error {
	var fullFilePath, fullFileDLURL string

	switch runtime.GOOS {
	case "windows":
		return errors.New("Windows is not currently supported for :" + cCoinName)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			fullFilePath = location + cDownloadFileArm32
			fullFileDLURL = cDownloadURL + cDownloadFileArm32
		case "arm64":
			fullFilePath = location + cDownloadFileArm64
			fullFileDLURL = cDownloadURL + cDownloadFileArm64
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			fullFilePath = location + cDownloadFileLin
			fullFileDLURL = cDownloadURL + cDownloadFileLin
		}
	}

	if err := rjminternet.DownloadFile(fullFilePath, fullFileDLURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", fullFilePath+fullFileDLURL, err)
	}

	// Unarchive the files
	if err := p.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}
	return nil
}

func (p Peercoin) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	} else {
		return cDaemonFileLin
	}
}

func (p Peercoin) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDirLin
	}
}

func (p Peercoin) HomeDirFullPath() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir

	if runtime.GOOS == "windows" {
		return fileutils.AddTrailingSlash(hd) + "appdata\\roaming\\" + fileutils.AddTrailingSlash(cHomeDirWin), nil
	} else {
		return fileutils.AddTrailingSlash(hd) + fileutils.AddTrailingSlash(cHomeDirLin), nil
	}
}

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (p Peercoin) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfCLI, sfD, sfTX, dirToRemove string

	switch runtime.GOOS {
	case "windows":
		return errors.New("windows is not currently supported for " + cCoinName)
	case "linux":
		switch runtime.GOARCH {
		case "arm", "arm64":
			srcPath = location + cExtractedDirLin + "bin/"
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			sfTX = cTxFileLin
			dirToRemove = location + cExtractedDirLin
		case "amd64":
			srcPath = location + cExtractedDirLin + "bin/"
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			sfTX = cTxFileLin
			dirToRemove = location + cExtractedDirLin
		default:
			return errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
		}
	default:
		return errors.New("unable to determine runtime.GOOS")
	}

	// If the coin-cli file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfCLI); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+sfCLI, location+sfCLI, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfCLI, location+sfCLI, err)
		}
	}
	if err := os.Chmod(location+sfCLI, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfCLI, err)
	}

	// If the coind file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfD); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+sfD, location+sfD, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfD, location+sfD, err)
		}
	}
	if err := os.Chmod(location+sfD, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfD, err)
	}

	// If the coitx file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfTX); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+sfTX, location+sfTX, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfTX, location+sfTX, err)
		}
	}
	if err := os.Chmod(location+sfTX, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfTX, err)
	}

	if err := os.RemoveAll(dirToRemove); err != nil {
		return err
	}

	return nil
}

func (p Peercoin) RPCDefaultUsername() string {
	return cRPCUser
}

func (p Peercoin) RPCDefaultPort() string {
	return cRPCPort
}

func (p *Peercoin) WalletInfo() (models.PPCWalletInfo, error) {
	var respStruct models.PPCWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetWalletInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+p.IPAddress+":"+p.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(p.RPCUser, p.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}

	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}

	// Check to see if the json response contains "unlocked_until"
	s := string(bodyResp)
	if !strings.Contains(s, "unlocked_until") {
		respStruct.Result.UnlockedUntil = -1
	}

	return respStruct, nil
}

func (p Peercoin) WalletSecurityState() (models.WEType, error) {
	wi, err := p.WalletInfo()
	if err != nil {
		return models.WETUnknown, errors.New("Unable to GetWalletSecurityState: " + err.Error())
	}

	if wi.Result.UnlockedUntil == 0 {
		return models.WETLocked, nil
	} else if wi.Result.UnlockedUntil == -1 {
		return models.WETUnencrypted, nil
	} else if wi.Result.UnlockedUntil > 0 {
		return models.WETUnlockedForStaking, nil
	} else {
		return models.WETUnknown, nil
	}
}

func (p Peercoin) StartDaemon(displayOutput bool, appFolder string, auth *models.CoinAuth) error {
	if runtime.GOOS == "windows" {
		//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
		fp := appFolder + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the peercoind daemon...")
		}

		cmdRun := exec.Command(appFolder + cDaemonFileLin)
		if err := cmdRun.Start(); err != nil {
			return err
		}
		if displayOutput {
			fmt.Println(cCoinName + " server starting")
		}

		//	stdout, err := cmdRun.StdoutPipe()
		//	if err != nil {
		//		return err
		//	}
		//	err = cmdRun.Start()
		//	if err != nil {
		//		return err
		//	}
		//
		//	buf := bufio.NewReader(stdout)
		//	num := 1
		//	for {
		//		line, _, _ := buf.ReadLine()
		//		if num > 3 {
		//			os.Exit(0)
		//		}
		//		num++
		//		if string(line) == "Peercoin server starting" {
		//			if displayOutput {
		//				fmt.Println("Peercoin server starting")
		//			}
		//			return nil
		//		} else {
		//			return errors.New("unable to start Peercoin server: " + string(line))
		//		}
		//	}
	}
	return nil
}

func (p Peercoin) StopDaemon(auth *models.CoinAuth) error {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return err
	}
	return nil
}

func (p Peercoin) TipAddress() string {
	return cTipAddress
}

func (p *Peercoin) unarchiveFile(fullFilePath, location string) error {
	if err := archiver.Unarchive(fullFilePath, location); err != nil {
		return fmt.Errorf("unable to unarchive file: %v - %v", fullFilePath, err)
	}
	switch runtime.GOOS {
	case "windows":
		return errors.New("Windows is not currently supported for :" + cCoinName)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			defer os.RemoveAll(location + cDownloadFileArm32)
		case "arm64":
			defer os.RemoveAll(location + cDownloadFileArm64)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			defer os.RemoveAll(location + cDownloadFileLin)
		}
	}

	defer os.Remove(fullFilePath)

	return nil
}
