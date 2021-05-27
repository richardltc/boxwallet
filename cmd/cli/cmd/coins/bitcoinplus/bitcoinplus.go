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
	"runtime"
	"strings"
	"time"

	"github.com/mholt/archiver"
	"github.com/theckman/yacspin"

	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "BitcoinPlus"
	cCoinNameAbbrev string = "XBC"

	cCoreVersion string = "2.8.2"
	//cDownloadFileArm32          = "bitcoinplus-" + CCoreVersionBitcoinPlus + "-arm-linux-gnueabihf.tar.gz"
	//CDFBitcoinPlusFileArm64          = "bitcoinplus-" + CCoreVersionBitcoinPlus + "-aarch64-linux-gnu.tar.gz"
	cDownloadFileLin32 = "bitcoinplus-" + cCoreVersion + "-linux32.tar.gz"
	cDownloadFileLin64 = "bitcoinplus-" + cCoreVersion + "-linux64.tar.gz"
	//CDFFilemacOSBitcoinPlus          = "bitcoinplus-" + CCoreVersionBitcoinPlus + "-osx64.tar.gz"
	//CDFFileWindowsBitcoinPlus        = "bitcoinplus-" + CCoreVersionBitcoinPlus + "-win64.zip"

	// Directory const
	cExtractedDirArm     string = "bitcoinplus-" + cCoreVersion + "/"
	cExtractedDirLinux   string = "" //"bitcoinplus-" + CCoreVersionBitcoinPlus + "/"
	cExtractedDirWindows string = "" //"bitcoinplus-" + CCoreVersionBitcoinPlus + "\\"

	cDownloadURL string = "https://github.com/bitcoinplusorg/xbcwalletsource/releases/download/v" + cCoreVersion + "/"

	// BitcoinPlus Wallet Constants
	cHomeDirLin string = ".bitcoinplus"
	cHomeDirWin string = "bitcoinplus"

	cTipAddress string = "BButzXzJj9KqhfEbF7rLxqN9jC7mT4MX15"

	// File constants
	cConfFile      string = "bitcoinplus.conf"
	cCliFile       string = "bitcoinplus-cli"
	cCliFileWin    string = "bitcoinplus-cli.exe"
	cDaemonFileLin string = "bitcoinplusd"
	cDaemonFileWin string = "bitcoinplusd.exe"
	cTxFile        string = "bitcoinplus-tx"
	cTxFileWin     string = "bitcoinplus-tx.exe"

	// pivx.conf file constants.
	cRPCUser string = "bitcoinplusrpc"
	cRPCPort string = "8885" // General CLI command constants

	cCommandGetBCInfo             string = "getblockchaininfo"
	cCommandGetInfo               string = "getinfo"
	cCommandGetStakingInfo        string = "getstakinginfo"
	cCommandListReceivedByAddress string = "listreceivedbyaddress"
	cCommandListTransactions      string = "listtransactions"
	cCommandGetNetworkInfo        string = "getnetworkinfo"
	cCommandGetNewAddress         string = "getnewaddress"
	cCommandGetWalletInfo         string = "getwalletinfo"
	cCommandSendToAddress         string = "sendtoaddress"
	cCommandMNSyncStatus1         string = "mnsync"
	cCommandMNSyncStatus2         string = "status"
	cCommandDumpHDInfo            string = "dumphdinfo" // ./divi-cli dumphdinfo

)

type XBC struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (x XBC) BootStrap(rpcUser, rpcPassword, ip, port string) {
	x.RPCUser = rpcUser
	x.RPCPassword = rpcPassword
	x.IPAddress = ip
	if port == "" {
		x.Port = cRPCPort
	} else {
		x.Port = port
	}
}

func (x *XBC) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (x XBC) AllBinaryFilesExist() (allExist bool, err error) {
	homeDir, err := x.HomeDirFullPath()
	if err != nil {
		return false, errors.New("unable to get HomeDir:" + err.Error())
	}

	if runtime.GOOS == "windows" {
		if !coins.FileExists(homeDir + cCliFileWin) {
			return false, nil
		}
		if !coins.FileExists(homeDir + cDaemonFileWin) {
			return false, nil
		}
		if !coins.FileExists(homeDir + cTxFileWin) {
			return false, nil
		}
	} else {
		if !coins.FileExists(homeDir + cCliFile) {
			return false, nil
		}
		if !coins.FileExists(homeDir + cDaemonFileLin) {
			return false, nil
		}
		if !coins.FileExists(homeDir + cTxFile) {
			return false, nil
		}
	}
	return true, nil
}

func (x XBC) ConfFile() string {
	return cConfFile
}

func (x XBC) CoinName() string {
	return cCoinName
}

func (x XBC) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (x XBC) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	}

	return cDaemonFileLin
}

func (x XBC) DaemonRunning() (bool, error) {
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

// DownloadCoin - Downloads the BitcoinPlus files into the specified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (x XBC) DownloadCoin(location string) error {
	var fullFilePath, fullFileDLURL string

	switch runtime.GOOS {
	case "windows":
		return errors.New("windows is not currently supported for :" + cCoinName)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			return errors.New("arm32 is not currently supported for :" + cCoinName)
		case "arm64":
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			fullFilePath = location + cDownloadFileLin32
			fullFileDLURL = cDownloadURL + cDownloadFileLin32
		case "amd64":
			fullFilePath = location + cDownloadFileLin64
			fullFileDLURL = cDownloadURL + cDownloadFileLin64
		}
	}

	if err := rjminternet.DownloadFile(fullFilePath, fullFileDLURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", fullFilePath+fullFileDLURL, err)
	}

	// Unarchive the files
	if err := x.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}
	return nil
}

func (x *XBC) BlockchainInfo() (models.XBCBlockchainInfo, error) {
	var respStruct models.XBCBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetBCInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+x.IPAddress+":"+x.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(x.RPCUser, x.RPCPassword)
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

func (x *XBC) Info() (models.XBCGetInfo, string, error) {
	var respStruct models.XBCGetInfo

	for i := 1; i < 300; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+x.IPAddress+":"+x.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(x.RPCUser, x.RPCPassword)
		req.Header.Set("Content-Type", "text/plain;")

		for j := 1; j < 50; j++ {
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				time.Sleep(1 * time.Second)
				continue
			}
			defer resp.Body.Close()
			bodyResp, err := ioutil.ReadAll(resp.Body)
			if err != nil {
				return respStruct, "", err
			}

			// Check to make sure we are not loading the wallet
			if bytes.Contains(bodyResp, []byte("Loading")) ||
				bytes.Contains(bodyResp, []byte("Rescanning")) ||
				bytes.Contains(bodyResp, []byte("Rewinding")) ||
				bytes.Contains(bodyResp, []byte("Verifying")) {
				// The wallet is still loading, so print message, and sleep for 3 seconds and try again.
				var errStruct models.GenericResponse
				err = json.Unmarshal(bodyResp, &errStruct)
				if err != nil {
					return respStruct, "", err
				}
				time.Sleep(1 * time.Second)
			} else {
				_ = json.Unmarshal(bodyResp, &respStruct)
				return respStruct, string(bodyResp), err
			}
		}
	}
	return respStruct, "", nil
}

func (x *XBC) InfoUI(spin *yacspin.Spinner) (models.XBCGetInfo, string, error) {
	var respStruct models.XBCGetInfo

	for i := 1; i < 600; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+x.IPAddress+":"+x.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(x.RPCUser, x.RPCPassword)
		req.Header.Set("Content-Type", "text/plain;")

		resp, err := http.DefaultClient.Do(req)
		//defer resp.Body.Close()
		if err != nil {
			spin.Message(" waiting for your " + cCoinName + " wallet to respond, this could take several minutes (ctrl-c to cancel)...")
			time.Sleep(1 * time.Second)
		} else {
			defer resp.Body.Close()
			bodyResp, err := ioutil.ReadAll(resp.Body)
			if err != nil {
				return respStruct, "", err
			}

			// Check to make sure we are not loading the wallet
			if bytes.Contains(bodyResp, []byte("Loading")) ||
				bytes.Contains(bodyResp, []byte("Rescanning")) ||
				bytes.Contains(bodyResp, []byte("Rewinding")) ||
				bytes.Contains(bodyResp, []byte("RPC in warm-up: Calculating money supply")) ||
				bytes.Contains(bodyResp, []byte("Verifying")) {
				// The wallet is still loading, so print message, and sleep for 1 second and try again..
				var errStruct models.GenericResponse
				err = json.Unmarshal(bodyResp, &errStruct)
				if err != nil {
					return respStruct, "", err
				}

				if bytes.Contains(bodyResp, []byte("Loading")) {
					spin.Message(" Your " + cCoinName + " wallet is *Loading*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Rescanning")) {
					spin.Message(" Your " + cCoinName + " wallet is *Rescanning*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Rewinding")) {
					spin.Message(" Your " + cCoinName + " wallet is *Rewinding*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Verifying")) {
					spin.Message(" Your " + cCoinName + " wallet is *Verifying*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Calculating money supply")) {
					spin.Message(" Your " + cCoinName + " wallet is *Calculating money supply*, this could take a while...")
				}
				time.Sleep(1 * time.Second)
			} else {
				_ = json.Unmarshal(bodyResp, &respStruct)
				return respStruct, string(bodyResp), err
			}
		}
	}
	return respStruct, "", nil
}

func (x *XBC) NetworkInfo() (models.XBCNetworkInfo, error) {
	var respStruct models.XBCNetworkInfo

	for i := 1; i < 50; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetNetworkInfo + "\",\"params\":[]}")

		req, err := http.NewRequest("POST", "http://"+x.IPAddress+":"+x.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(x.RPCUser, x.RPCPassword)
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
			bytes.Contains(bodyResp, []byte("Rescanning")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again
			time.Sleep(5 * time.Second)
		} else {
			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
}

func (x *XBC) NewAddress() (models.XBCGetNewAddress, error) {
	var respStruct models.XBCGetNewAddress

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+x.IPAddress+":"+x.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(x.RPCUser, x.RPCPassword)
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

func (x *XBC) StakingInfo() (models.XBCStakingInfo, error) {
	var respStruct models.XBCStakingInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetStakingInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+x.IPAddress+":"+x.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(x.RPCUser, x.RPCPassword)
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

func (x XBC) HomeDirFullPath() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir

	if runtime.GOOS == "windows" {
		return coins.AddTrailingSlash(hd) + "appdata\\roaming\\" + coins.AddTrailingSlash(cHomeDirWin), nil
	} else {
		return coins.AddTrailingSlash(hd) + coins.AddTrailingSlash(cHomeDirLin), nil
	}
}

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (x XBC) Install(location string) error {

	// Copy files to correct location
	var srcPath, srcFileCLI, srcFileDaemon, srcFileTX string

	switch runtime.GOOS {
	case "windows":
		return errors.New("windows is not currently supported for " + cCoinName)
	case "linux":
		switch runtime.GOARCH {
		case "arm", "arm64":
			srcPath = location + cExtractedDirLinux
			srcFileCLI = cCliFile
			srcFileDaemon = cDaemonFileLin
			srcFileTX = cTxFile
		case "amd64":
			srcPath = location + cExtractedDirLinux
			srcFileCLI = cCliFile
			srcFileDaemon = cDaemonFileLin
			srcFileTX = cTxFile
		default:
			return errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
		}
	default:
		return errors.New("unable to determine runtime.GOOS")
	}

	// If the coin-cli file doesn't already exists the copy it.
	if _, err := os.Stat(location + srcFileCLI); os.IsNotExist(err) {
		if err := coins.FileCopy(srcPath+srcFileCLI, location+srcFileCLI, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileCLI, location+srcFileCLI, err)
		}
	}
	if err := os.Chmod(location+srcFileCLI, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+srcFileCLI, err)
	}

	// If the coind file doesn't already exists the copy it.
	if _, err := os.Stat(location + srcFileDaemon); os.IsNotExist(err) {
		if err := coins.FileCopy(srcPath+srcFileDaemon, location+srcFileDaemon, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileDaemon, location+srcFileDaemon, err)
		}
	}
	if err := os.Chmod(location+srcFileDaemon, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+srcFileDaemon, err)
	}

	// If the coitx file doesn't already exists the copy it.
	if _, err := os.Stat(location + srcFileTX); os.IsNotExist(err) {
		if err := coins.FileCopy(srcPath+srcFileTX, location+srcFileTX, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileTX, location+srcFileTX, err)
		}
	}
	if err := os.Chmod(location+srcFileTX, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+srcFileTX, err)
	}

	return nil
}

func (x *XBC) ListReceivedByAddress(includeZero bool) (models.XBCListReceivedByAddress, error) {
	var respStruct models.XBCListReceivedByAddress

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"" + cCommandListReceivedByAddress + "\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"" + cCommandListReceivedByAddress + "\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
	req, err := http.NewRequest("POST", "http://"+x.IPAddress+":"+x.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(x.RPCUser, x.RPCPassword)
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

func (x *XBC) ListTransactions() (models.XBCListTransactions, error) {
	var respStruct models.XBCListTransactions

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandListTransactions + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+x.IPAddress+":"+x.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(x.RPCUser, x.RPCPassword)
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

func (x XBC) RPCDefaultUsername() string {
	return cRPCUser
}

func (x XBC) RPCDefaultPort() string {
	return cRPCPort
}

func (x *XBC) StartDaemon(displayOutput bool) error {
	b, _ := x.DaemonRunning()
	if b {
		return nil
	}
	path, err := x.HomeDirFullPath()
	if err != nil {
		return errors.New("Unable to get HomeDirFullPath: " + err.Error())
	}

	if runtime.GOOS == "windows" {
		fp := path + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the " + cCoinName + " daemon...")
		}

		fp := path + cDaemonFileLin
		cmdRun := exec.Command(fp)
		//stdout, err := cmdRun.StdoutPipe()
		//if err != nil {
		//	return err
		//}
		if err := cmdRun.Start(); err != nil {
			return err
		}
		if displayOutput {
			fmt.Println(cCoinName + " server starting")
		}

	}
	return nil
}

func (x *XBC) StopDaemon() error {
	// var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+x.IPAddress+":"+x.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(x.RPCUser, x.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	// bodyResp, err := ioutil.ReadAll(resp.Body)
	// if err != nil {
	// 	return err
	// }
	// err = json.Unmarshal(bodyResp, &respStruct)
	// if err != nil {
	// 	return respStruct, err
	// }
	return nil
}

func (x XBC) TipAddress() string {
	return cTipAddress
}

func (x *XBC) WalletInfo() (models.XBCWalletInfo, error) {
	var respStruct models.XBCWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetWalletInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+x.IPAddress+":"+x.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(x.RPCUser, x.RPCPassword)
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

func (x XBC) WalletReady() bool {
	i, _, _ := x.Info()
	if i.Result.Version != 0 {
		return true
	}

	return false
}

func (x XBC) WalletResync() error {
	daemonRunning, err := x.DaemonRunning()
	if err != nil {
		return errors.New("Unable to determine DaemonRunning: " + err.Error())
	}
	if daemonRunning {
		return errors.New("Daemon is still running, please stop first.")
	}

	coinDir, err := x.HomeDirFullPath()
	if err != nil {
		return errors.New("Unable to determine HomeDirFullPath: " + err.Error())
	}
	arg1 := "-resync"

	cRun := exec.Command(coinDir+cDaemonFileLin, arg1)
	if err := cRun.Run(); err != nil {
		return fmt.Errorf("unable to run "+cDaemonFileLin+" "+arg1+": %v", err)
	}

	return nil
}

func (x *XBC) WalletSecurityState() (models.WEType, error) {
	wi, err := x.WalletInfo()
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

func (x XBC) unarchiveFile(fullFilePath, location string) error {
	if err := archiver.Unarchive(fullFilePath, location); err != nil {
		return fmt.Errorf("unable to unarchive file: %v - %v", fullFilePath, err)
	}
	switch runtime.GOOS {
	case "windows":
		return errors.New("windows is not currently supported for :" + cCoinName)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			return errors.New("arm32 is not currently supported for :" + cCoinName)
		case "arm64":
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			defer os.RemoveAll(location + cDownloadFileLin32)
		case "amd64":
			defer os.RemoveAll(location + cDownloadFileLin64)
		}
	}

	defer os.Remove(fullFilePath)

	return nil
}
