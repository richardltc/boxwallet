package bend

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"runtime"
	"strings"
	"time"

	"github.com/mholt/archiver"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "Groestlcoin"
	cCoinNameAbbrev string = "GRS"

	cCoreVersion       string = "2.21.1"
	cDownloadFileArm32 string = "groestlcoin-" + cCoreVersion + "-arm-linux-gnueabihf.tar.gz"
	cDownloadFileLin   string = "groestlcoin-" + cCoreVersion + "-x86_64-linux-gnu.tar.gz"
	cDownloadFileWin   string = "groestlcoin-" + cCoreVersion + "-win64.zip"

	cExtractedDirLin = "groestlcoin-" + cCoreVersion + "/"
	cExtractedDirWin = "groestlcoin-" + cCoreVersion + "\\"

	cDownloadURL string = "https://github.com/Groestlcoin/groestlcoin/releases/download/v" + cCoreVersion + "/"

	cHomeDirLin string = ".groestlcoin"
	cHomeDirWin string = "GROESTLCOIN"

	// Files.
	cConfFile      string = "groestlcoin.conf"
	cCliFileLin    string = "groestlcoin-cli"
	cCliFileWin    string = "groestlcoin-cli.exe"
	cDaemonFileLin string = "groestlcoind"
	cDaemonFileWin string = "groestlcoind.exe"
	cTxFileLin     string = "groestlcoin-tx"
	cTxFileWin     string = "groestlcoin-tx.exe"

	cTipAddress string = "3HBqpZ1JH125FmW52GYjoBpNEAwyxjL9t9"

	// Networking
	cRPCUser string = "groestlcoinrpc"
	cRPCPort string = "1441"
)

type Groestlcoin struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (g Groestlcoin) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	g.RPCUser = rpcUser
	g.RPCPassword = rpcPassword
	g.IPAddress = ip
	g.Port = port
}

func (g Groestlcoin) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (g Groestlcoin) AllBinaryFilesExist(dir string) (bool, error) {
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

func (g *Groestlcoin) BlockchainInfo() (models.GRSBlockchainInfo, error) {
	var respStruct models.GRSBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+g.IPAddress+":"+g.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(g.RPCUser, g.RPCPassword)
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
	return respStruct, nil
}

func (g Groestlcoin) ConfFile() string {
	return cConfFile
}

func (g Groestlcoin) CoinName() string {
	return cCoinName
}

func (g Groestlcoin) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

// DownloadCoin - Downloads the Syscoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (g Groestlcoin) DownloadCoin(location string) error {
	var fullFilePath, fullFileDLURL string

	switch runtime.GOOS {
	case "windows":
		fullFilePath = location + cDownloadFileWin
		fullFileDLURL = cDownloadURL + cDownloadFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			fullFilePath = location + cDownloadFileArm32
			fullFileDLURL = cDownloadURL + cDownloadFileArm32
		case "arm64":
			return errors.New("arm64 is not currently supported for :" + cCoinName)
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
	if err := g.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}
	return nil
}

func (g Groestlcoin) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	} else {
		return cDaemonFileLin
	}
}

func (g *Groestlcoin) NewAddress() (models.GRSNewAddress, error) {
	var respStruct models.GRSNewAddress

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+g.IPAddress+":"+g.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(g.RPCUser, g.RPCPassword)
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

	return respStruct, nil
}

func (g Groestlcoin) RPCDefaultUsername() string {
	return cRPCUser
}

func (g Groestlcoin) RPCDefaultPort() string {
	return cRPCPort
}

func (g *Groestlcoin) WalletInfo() (models.GRSWalletInfo, error) {
	var respStruct models.GRSWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getwalletinfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+g.IPAddress+":"+g.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(g.RPCUser, g.RPCPassword)
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
	s := string([]byte(bodyResp))
	if !strings.Contains(s, "unlocked_until") {
		respStruct.Result.UnlockedUntil = -1
	}

	return respStruct, nil
}

//func GetBlockchainSyncTxtGRS(synced bool, bci *GRSBlockchainInfoRespStruct) string {
//	s := ConvertBCVerification(bci.Result.Verificationprogress)
//	if s == "0.0" {
//		s = ""
//	} else {
//		s = s + "%"
//	}
//
//	if !synced {
//		if bci.Result.Verificationprogress > gLastBCSyncPos {
//			gLastBCSyncPos = bci.Result.Verificationprogress
//			return "Blockchain:  [syncing " + s + " ](fg:yellow)"
//		} else {
//			gLastBCSyncPos = bci.Result.Verificationprogress
//			return "Blockchain:  [waiting " + s + " ](fg:yellow)"
//		}
//	} else {
//		return "Blockchain:  [synced " + CUtfTickBold + "](fg:green)"
//	}
//}

func (g *Groestlcoin) NetworkInfo() (models.GRSNetworkInfo, error) {
	var respStruct models.GRSNetworkInfo

	for i := 1; i < 50; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnetworkinfo\",\"params\":[]}")

		req, err := http.NewRequest("POST", "http://"+g.IPAddress+":"+g.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(g.RPCUser, g.RPCPassword)
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

		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again..
			time.Sleep(5 * time.Second)
		} else {
			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
}

func (g Groestlcoin) TipAddress() string {
	return cTipAddress
}

func (g Groestlcoin) WalletSecurityState() (models.WEType, error) {
	wi, err := g.WalletInfo()
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

func (g *Groestlcoin) ListReceivedByAddress(includeZero bool) (models.GRSListReceivedByAddress, error) {
	var respStruct models.GRSListReceivedByAddress

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
	req, err := http.NewRequest("POST", "http://"+g.IPAddress+":"+g.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(g.RPCUser, g.RPCPassword)
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

	return respStruct, nil
}

func (g Groestlcoin) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDirLin
	}
}

func (g Groestlcoin) HomeDirFullPath() (string, error) {
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
func (g Groestlcoin) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfCLI, sfD, sfTX, dirToRemove string

	switch runtime.GOOS {
	case "windows":
		srcPath = location + cDownloadFileWin
		sfCLI = cCliFileWin
		sfD = cDaemonFileWin
		sfTX = cTxFileWin
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

func (g *Groestlcoin) StartDaemon(displayOutput bool) error {
	if runtime.GOOS == "windows" {
		//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
		fullPath := cHomeDirWin + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fullPath)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the groestlcoin daemon...")
		}

		cmdRun := exec.Command(cHomeDirLin + cDaemonFileLin)
		//stdout, err := cmdRun.StdoutPipe()
		err := cmdRun.Start()
		if err != nil {
			return err
		}
		fmt.Println("Groestlcoin server starting")
	}
	return nil
}

func (g *Groestlcoin) StopDaemon(displayOut bool) (models.GenericResponse, error) {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+g.IPAddress+":"+g.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(g.RPCUser, g.RPCPassword)
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
	return respStruct, nil
}

func (g *Groestlcoin) unarchiveFile(fullFilePath, location string) error {
	if err := archiver.Unarchive(fullFilePath, location); err != nil {
		return fmt.Errorf("unable to unarchive file: %v - %v", fullFilePath, err)
	}
	switch runtime.GOOS {
	case "windows":
		defer os.RemoveAll(location + cDownloadFileWin)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			defer os.RemoveAll(location + cDownloadFileArm32)
		case "arm64":
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			defer os.RemoveAll(location + cDownloadFileLin)
		}
	}

	defer os.Remove(fullFilePath)

	return nil
}
