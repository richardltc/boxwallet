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
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/mholt/archiver"
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
	//cExtractedDirArm     string = "bitcoinplus-" + cCoreVersion + "/"
	cExtractedDirLinux string = "" //"bitcoinplus-" + CCoreVersionBitcoinPlus + "/"
	//cExtractedDirWindows string = "" //"bitcoinplus-" + CCoreVersionBitcoinPlus + "\\"

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

)

type XBC struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (x XBC) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	x.RPCUser = rpcUser
	x.RPCPassword = rpcPassword
	x.IPAddress = ip
	if port == "" {
		x.Port = cRPCPort
	} else {
		x.Port = port
	}
}

func (x XBC) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (x XBC) AllBinaryFilesExist(location string) (allExist bool, err error) {
	if runtime.GOOS == "windows" {
		if !fileutils.FileExists(location + cCliFileWin) {
			return false, nil
		}
		if !fileutils.FileExists(location + cDaemonFileWin) {
			return false, nil
		}
		if !fileutils.FileExists(location + cTxFileWin) {
			return false, nil
		}
	} else {
		if !fileutils.FileExists(location + cCliFile) {
			return false, nil
		}
		if !fileutils.FileExists(location + cDaemonFileLin) {
			return false, nil
		}
		if !fileutils.FileExists(location + cTxFile) {
			return false, nil
		}
	}
	return true, nil
}

func (x XBC) AnyAddresses(auth *models.CoinAuth) (bool, error) {
	addresses, err := x.ListReceivedByAddress(auth, false)
	if err != nil {
		return false, err
	}
	if len(addresses.Result) > 0 {
		return true, nil
	}
	return false, nil
}

func (x XBC) BlockchainIsSynced(coinAuth *models.CoinAuth) (bool, error) {
	bci, err := x.BlockchainInfo(coinAuth)
	if err != nil {
		return false, err
	}

	if bci.Result.Verificationprogress > 0.99999 {
		return true, nil
	}

	return false, nil
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

func (x *XBC) BlockchainInfo(coinAuth *models.CoinAuth) (models.XBCBlockchainInfo, error) {
	var respStruct models.XBCBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetBCInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
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
		return fileutils.AddTrailingSlash(hd) + "appdata\\roaming\\" + fileutils.AddTrailingSlash(cHomeDirWin), nil
	} else {
		return fileutils.AddTrailingSlash(hd) + fileutils.AddTrailingSlash(cHomeDirLin), nil
	}
}

func (x XBC) Info(auth *models.CoinAuth) (models.XBCGetInfo, string, error) {
	var respStruct models.XBCGetInfo

	for i := 1; i < 300; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
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

//func (x *XBC) InfoUI(auth *models.CoinAuth, spin *yacspin.Spinner) (models.XBCGetInfo, string, error) {
//	var respStruct models.XBCGetInfo
//
//	for i := 1; i < 600; i++ {
//		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetInfo + "\",\"params\":[]}")
//		req, err := http.NewRequest("POST", "http://"+x.IPAddress+":"+x.Port, body)
//		if err != nil {
//			return respStruct, "", err
//		}
//		req.SetBasicAuth(x.RPCUser, x.RPCPassword)
//		req.Header.Set("Content-Type", "text/plain;")
//
//		resp, err := http.DefaultClient.Do(req)
//		//defer resp.Body.Close()
//		if err != nil {
//			spin.Message(" waiting for your " + cCoinName + " wallet to respond, this could take several minutes (ctrl-c to cancel)...")
//			time.Sleep(1 * time.Second)
//		} else {
//			defer resp.Body.Close()
//			bodyResp, err := ioutil.ReadAll(resp.Body)
//			if err != nil {
//				return respStruct, "", err
//			}
//
//			// Check to make sure we are not loading the wallet
//			if bytes.Contains(bodyResp, []byte("Loading")) ||
//				bytes.Contains(bodyResp, []byte("Rescanning")) ||
//				bytes.Contains(bodyResp, []byte("Rewinding")) ||
//				bytes.Contains(bodyResp, []byte("RPC in warm-up: Calculating money supply")) ||
//				bytes.Contains(bodyResp, []byte("Verifying")) {
//				// The wallet is still loading, so print message, and sleep for 1 second and try again..
//				var errStruct models.GenericResponse
//				err = json.Unmarshal(bodyResp, &errStruct)
//				if err != nil {
//					return respStruct, "", err
//				}
//
//				if bytes.Contains(bodyResp, []byte("Loading")) {
//					spin.Message(" Your " + cCoinName + " wallet is *Loading*, this could take a while...")
//				} else if bytes.Contains(bodyResp, []byte("Rescanning")) {
//					spin.Message(" Your " + cCoinName + " wallet is *Rescanning*, this could take a while...")
//				} else if bytes.Contains(bodyResp, []byte("Rewinding")) {
//					spin.Message(" Your " + cCoinName + " wallet is *Rewinding*, this could take a while...")
//				} else if bytes.Contains(bodyResp, []byte("Verifying")) {
//					spin.Message(" Your " + cCoinName + " wallet is *Verifying*, this could take a while...")
//				} else if bytes.Contains(bodyResp, []byte("Calculating money supply")) {
//					spin.Message(" Your " + cCoinName + " wallet is *Calculating money supply*, this could take a while...")
//				}
//				time.Sleep(1 * time.Second)
//			} else {
//				_ = json.Unmarshal(bodyResp, &respStruct)
//				return respStruct, string(bodyResp), err
//			}
//		}
//	}
//	return respStruct, "", nil
//}

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
		if err := fileutils.FileCopy(srcPath+srcFileCLI, location+srcFileCLI, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileCLI, location+srcFileCLI, err)
		}
	}
	if err := os.Chmod(location+srcFileCLI, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+srcFileCLI, err)
	}

	// If the coind file doesn't already exists the copy it.
	if _, err := os.Stat(location + srcFileDaemon); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+srcFileDaemon, location+srcFileDaemon, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileDaemon, location+srcFileDaemon, err)
		}
	}
	if err := os.Chmod(location+srcFileDaemon, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+srcFileDaemon, err)
	}

	// If the coitx file doesn't already exists the copy it.
	if _, err := os.Stat(location + srcFileTX); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+srcFileTX, location+srcFileTX, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileTX, location+srcFileTX, err)
		}
	}
	if err := os.Chmod(location+srcFileTX, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+srcFileTX, err)
	}

	return nil
}

func (x *XBC) ListReceivedByAddress(coinAuth *models.CoinAuth, includeZero bool) (models.XBCListReceivedByAddress, error) {
	var respStruct models.XBCListReceivedByAddress

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"" + models.CCommandListReceivedByAddress + "\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"" + models.CCommandListReceivedByAddress + "\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
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

func (x XBC) ListTransactions(auth *models.CoinAuth) (models.XBCListTransactions, error) {
	var respStruct models.XBCListTransactions

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandListTransactions + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
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

func (x XBC) NetworkDifficultyInfo() (float64, float64, error) {
	// https://chainz.cryptoid.info/ftc/api.dws?q=getdifficulty

	resp, err := http.Get("https://chainz.cryptoid.info/" + strings.ToLower(x.CoinNameAbbrev()) + "/api.dws?q=getdifficulty")
	if err != nil {
		return 0, 0, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return 0, 0, err
	}

	var fGood float64
	var fWarning float64
	// Now calculate the correct levels...
	if fDiff, err := strconv.ParseFloat(string(body), 32); err == nil {
		fGood = fDiff * 0.75
		fWarning = fDiff * 0.50
	}
	return fGood, fWarning, nil
}

func (x *XBC) NetworkInfo(coinAuth *models.CoinAuth) (models.XBCNetworkInfo, error) {
	var respStruct models.XBCNetworkInfo

	for i := 1; i < 50; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetNetworkInfo + "\",\"params\":[]}")

		req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
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

func (x *XBC) NewAddress(coinAuth *models.CoinAuth) (models.XBCGetNewAddress, error) {
	var respStruct models.XBCGetNewAddress

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
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

func (x *XBC) StakingInfo(coinAuth *models.CoinAuth) (models.XBCStakingInfo, error) {
	var respStruct models.XBCStakingInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetStakingInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
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

func (x XBC) StartDaemon(displayOutput bool, appFolder string, auth *models.CoinAuth) error {
	b, _ := x.DaemonRunning()
	if b {
		return nil
	}
	//path, err := x.HomeDirFullPath()
	//if err != nil {
	//	return errors.New("Unable to get HomeDirFullPath: " + err.Error())
	//}

	if runtime.GOOS == "windows" {
		fp := appFolder + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the " + cCoinName + " daemon...")
		}

		fp := appFolder + cDaemonFileLin
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

func (x XBC) StopDaemon(auth *models.CoinAuth) error {
	// var respStruct models.GenericResponse

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

func (x XBC) UpdateTickerInfo() (ticker models.XBCTicker, err error) {
	resp, err := http.Get("https://ticker.neist.io/XBC")
	if err != nil {
		return ticker, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return ticker, err
	}
	err = json.Unmarshal(body, &ticker)
	if err != nil {
		return ticker, err
	}
	return ticker, nil
}

func (x XBC) WalletAddress(auth *models.CoinAuth) (string, error) {
	var sAddress string
	addresses, _ := x.ListReceivedByAddress(auth, true)
	if len(addresses.Result) > 0 {
		sAddress = addresses.Result[0].Address
	} else {
		res, err := x.NewAddress(auth)
		if err != nil {
			return "", err
		}
		sAddress = res.Result
	}
	return sAddress, nil
}

func (x XBC) WalletEncrypt(coinAuth *models.CoinAuth, pw string) (be.GenericRespStruct, error) {
	var respStruct be.GenericRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandEncryptWallet + "\",\"params\":[\"" + pw + "\"]}")
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
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

func (x *XBC) WalletInfo(coinAuth *models.CoinAuth) (models.XBCWalletInfo, error) {
	var respStruct models.XBCWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetWalletInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
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

func (x XBC) WalletLoadingStatus(auth *models.CoinAuth) models.WLSType {
	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
	if err != nil {
		return models.WLSTUnknown
	}
	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return models.WLSTWaitingForResponse
	} else {
		defer resp.Body.Close()
		bodyResp, err := ioutil.ReadAll(resp.Body)
		if err != nil {
			return models.WLSTWaitingForResponse
		}

		if bytes.Contains(bodyResp, []byte("Loading")) {
			return models.WLSTLoading
		}
		if bytes.Contains(bodyResp, []byte("Rescanning")) {
			return models.WLSTRescanning
		}
		if bytes.Contains(bodyResp, []byte("Rewinding")) {
			return models.WLSTRewinding
		}
		if bytes.Contains(bodyResp, []byte("Verifying")) {
			return models.WLSTVerifying
		}
		if bytes.Contains(bodyResp, []byte("Calculating money supply")) {
			return models.WLSTCalculatingMoneySupply
		}
	}
	return models.WLSTReady
}

func (x XBC) WalletNeedsEncrypting(coinAuth *models.CoinAuth) (bool, error) {
	wi, err := x.WalletInfo(coinAuth)
	if err != nil {
		return true, errors.New("Unable to perform WalletInfo " + err.Error())
	}

	if wi.Result.UnlockedUntil < 0 {
		return true, nil
	}

	return false, nil
}

func (x XBC) WalletResync(appFolder string) error {
	daemonRunning, err := x.DaemonRunning()
	if err != nil {
		return errors.New("Unable to determine DaemonRunning: " + err.Error())
	}
	if daemonRunning {
		return errors.New("daemon is still running, please stop first")
	}

	arg1 := "-resync"

	cRun := exec.Command(appFolder+cDaemonFileLin, arg1)
	if err := cRun.Run(); err != nil {
		return fmt.Errorf("unable to run "+cDaemonFileLin+" "+arg1+": %v", err)
	}

	return nil
}

func (x XBC) WalletSecurityState(coinAuth *models.CoinAuth) (models.WEType, error) {
	wi, err := x.WalletInfo(coinAuth)
	if err != nil {
		return models.WETUnknown, errors.New("Unable to determine WalletSecurityState: " + err.Error())
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

func (x XBC) WalletUnlock(coinAuth *models.CoinAuth, pw string) error {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",60]}")
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
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

func (x XBC) WalletUnlockFS(coinAuth *models.CoinAuth, pw string) error {
	var respStruct be.GenericRespStruct
	var body *strings.Reader

	// BitcoinPlus, doesn't currently support the "true" parameter to unlock for staking, so we're just adding an "unlock" command here
	// until Peter has fixed it...
	// todo Fix this in the future so that it *only* unlocks for staking.
	body = strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",9999999]}")

	//body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0,true]}")
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
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
	if err != nil || respStruct.Error != nil {
		return err
	}
	return nil
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
