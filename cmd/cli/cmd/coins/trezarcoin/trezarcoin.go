package bend

import (
	"bufio"
	"bytes"
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
	"strconv"
	"strings"
	"time"

	"github.com/mholt/archiver"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "Trezarcoin"
	cCoinNameAbbrev string = "TZC"

	cCoreVersion       string = "2.1.3"
	cDownloadFileArm32 string = cCoreVersion + "-rpi.zip"
	cDownloadFileLin64 string = "trezarcoin-" + cCoreVersion + "-linux64.tar.gz"
	cDownloadFileWin   string = "trezarcoin-" + cCoreVersion + "-win64-setup.exe"

	cExtractedDirLin = "trezarcoin-" + cCoreVersion + "/"
	cExtractedDirArm = cCoreVersion + "-rpi/"

	cAPIURL      string = "https://api.github.com/repos/TrezarCoin/TrezarCoin/releases/latest"
	cDownloadURL string = "https://github.com/TrezarCoin/TrezarCoin/releases/download/v" + cCoreVersion + ".0/"

	cHomeDirLin string = ".trezarcoin"
	cHomeDirWin string = "TREZARCOIN"

	cConfFile      string = "trezarcoin.conf"
	cCliFileLin    string = "trezarcoin-cli"
	cCliFileWin    string = "trezarcoin-cli.exe"
	cDaemonFileLin string = "trezarcoind"
	cDaemonFileWin string = "trezarcoind.exe"
	cTxFileLin     string = "trezarcoin-tx"
	cTxFileWin     string = "trezarcoin-tx.exe"

	cTipAddress string = "TnkHScr6iTcfK11GDPFjNgJ7V3GZtHEy9V"

	// trezarcoin.conf file constant.
	cRPCUser string = "trezarcoinrpc"
	cRPCPort string = "17299"
)

type Trezarcoin struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (t Trezarcoin) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	t.RPCUser = rpcUser
	t.RPCPassword = rpcPassword
	t.IPAddress = ip
	t.Port = port
}

func (t Trezarcoin) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (t Trezarcoin) AllBinaryFilesExist(dir string) (bool, error) {
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

func archStrToFile(arch string, ghInfo *models.GithubInfo) (fileName string) {
	for _, a := range ghInfo.Assets {
		if strings.Contains(a.Name, arch) {
			return a.Name
		}
	}

	return ""
}

func archStrToFileDownloadURL(arch string, ghInfo *models.GithubInfo) string {
	for _, a := range ghInfo.Assets {
		if strings.Contains(a.BrowserDownloadURL, arch) {
			return a.BrowserDownloadURL
		}
	}

	return ""
}

func (t Trezarcoin) AnyAddresses(auth *models.CoinAuth) (bool, error) {
	addresses, err := t.ListReceivedByAddress(auth, false)
	if err != nil {
		return false, err
	}
	if len(addresses.Result) > 0 {
		return true, nil
	}

	return false, nil
}

// BlockchainDataExists - Returns true if the Blockchain data exists for the specified coin
func (t Trezarcoin) BlockchainDataExists() (bool, error) {
	coinDir, err := t.HomeDirFullPath()
	if err != nil {
		return false, errors.New("unable to HomeDirFullPath - BlockchainDataExists")
	}

	// If the "blocks" directory already exists, return.
	if _, err := os.Stat(coinDir + "blocks"); !os.IsNotExist(err) {
		err := errors.New("The directory: " + coinDir + "blocks already exists")
		return true, err
	}

	// If the "chainstate" directory already exists, return
	if _, err := os.Stat(coinDir + "chainstate"); !os.IsNotExist(err) {
		err := errors.New("The directory: " + coinDir + "chainstate already exists")
		return true, err
	}

	return false, nil
}

func (t Trezarcoin) BlockchainInfo(auth *models.CoinAuth) (models.TZCBlockchainInfo, error) {
	var respStruct models.TZCBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
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

func (t Trezarcoin) BlockchainIsSynced(coinAuth *models.CoinAuth) (bool, error) {
	bci, err := t.BlockchainInfo(coinAuth)
	if err != nil {
		return false, err
	}

	if bci.Result.Verificationprogress > 0.99999 {
		return true, nil
	}

	return false, nil
}

func (t Trezarcoin) ConfFile() string {
	return cConfFile
}

func (t Trezarcoin) CoinName() string {
	return cCoinName
}

func (t Trezarcoin) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (t Trezarcoin) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	} else {
		return cDaemonFileLin
	}
}

func (t Trezarcoin) DaemonRunning() (bool, error) {
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
	}

	return false, err
}

// DownloadCoin - Downloads the Trezarcoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (t Trezarcoin) DownloadCoin(location string) error {
	var fullFilePath string
	ghInfo, err := latestAssets()
	if err != nil {
		return err
	}

	downloadFile, err := latestDownloadFile(&ghInfo)
	if err != nil {
		return err
	}

	fullFileDLURL, err := latestDownloadFileURL(&ghInfo)
	if err != nil {
		return err
	}

	fullFilePath = location + downloadFile

	//switch runtime.GOOS {
	//case "windows":
	//	fullFilePath = location + cDownloadFileWin
	//	fullFileDLURL = cDownloadURL + cDownloadFileWin
	//case "linux":
	//	switch runtime.GOARCH {
	//	case "arm":
	//		fullFilePath = location + cDownloadFileArm32
	//		fullFileDLURL = cDownloadURL + cDownloadFileArm32
	//	case "arm64":
	//		return errors.New("linux 386 is not currently supported for :" + cCoinName)
	//	case "386":
	//		return errors.New("linux 386 is not currently supported for :" + cCoinName)
	//	case "amd64":
	//		fullFilePath = location + cDownloadFileLin64
	//		fullFileDLURL = cDownloadURL + cDownloadFileLin64
	//	}
	//}

	if err := rjminternet.DownloadFile(fullFilePath, fullFileDLURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", fullFilePath+fullFileDLURL, err)
	}

	// Unarchive the files
	if err := t.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}

	return nil
}

func (t Trezarcoin) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDirLin
	}
}

func (t Trezarcoin) HomeDirFullPath() (string, error) {
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

func (t Trezarcoin) Info(auth *models.CoinAuth) (models.TZCGetInfo, string, error) {
	var respStruct models.TZCGetInfo

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
				bytes.Contains(bodyResp, []byte("RPC in warm-up")) ||
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

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (t Trezarcoin) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfCLI, sfD, sfTX string

	switch runtime.GOOS {
	case "windows":
		srcPath = location + cDownloadFileWin
		sfCLI = cCliFileWin
		sfD = cDaemonFileWin
		sfTX = cTxFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm", "arm64":
			srcPath = location + cExtractedDirArm
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			sfTX = cTxFileLin
		case "amd64":
			srcPath = location + cExtractedDirLin
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			sfTX = cTxFileLin
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

	return nil
}

func latestDownloadFile(ghInfo *models.GithubInfo) (string, error) {
	var sFile string
	switch runtime.GOOS {
	case "windows":
		sFile = archStrToFile("win64", ghInfo)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			sFile = archStrToFile("arm", ghInfo)
		case "arm64":
			sFile = archStrToFile("aarch64", ghInfo)
		case "386":
			return "", errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			sFile = archStrToFile("x86_64", ghInfo)
		}
	}

	if sFile == "" {
		return "", errors.New("unable to determine download url - latestDownloadFileURL")
	}

	return sFile, nil
}

func latestDownloadFileURL(ghInfo *models.GithubInfo) (string, error) {
	var sURL string
	switch runtime.GOOS {
	case "windows":
		sURL = archStrToFileDownloadURL("win64", ghInfo)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			sURL = archStrToFileDownloadURL("arm", ghInfo)
		case "arm64":
			sURL = archStrToFileDownloadURL("aarch64", ghInfo)
		case "386":
			return "", errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			sURL = archStrToFileDownloadURL("x86_64", ghInfo)
		}
	}

	if sURL == "" {
		return "", errors.New("unable to determine download url - latestDownloadFileURL")
	}

	return sURL, nil
}

func latestAssets() (models.GithubInfo, error) {
	var ghInfo models.GithubInfo

	resp, err := http.Get(cAPIURL)
	if err != nil {
		return ghInfo, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return ghInfo, err
	}
	err = json.Unmarshal(body, &ghInfo)
	if err != nil {
		return ghInfo, err
	}

	return ghInfo, nil
}

func (t Trezarcoin) ListReceivedByAddress(coinAuth *models.CoinAuth, includeZero bool) (models.TZCListReceivedByAddress, error) {
	var respStruct models.TZCListReceivedByAddress

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
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

func (t Trezarcoin) ListTransactions(auth *models.CoinAuth) (models.TZCListTransactions, error) {
	var respStruct models.TZCListTransactions

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"listtransactions\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(t.RPCUser, t.RPCPassword)
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

func (t Trezarcoin) NetworkDifficultyInfo() (float64, float64, error) {
	// https://chainz.cryptoid.info/ftc/api.dws?q=getdifficulty

	resp, err := http.Get("https://chainz.cryptoid.info/" + strings.ToLower(t.CoinNameAbbrev()) + "/api.dws?q=getdifficulty")
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

func (t Trezarcoin) NetworkInfo(auth *models.CoinAuth) (models.TZCNetworkInfo, error) {
	var respStruct models.TZCNetworkInfo

	for i := 1; i < 50; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetNetworkInfo + "\",\"params\":[]}")

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

		// Check to make sure we are not loading the wallet.
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

func (t Trezarcoin) NewAddress(auth *models.CoinAuth) (models.TZCGetNewAddress, error) {
	var respStruct models.TZCGetNewAddress

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetNewAddress + "\",\"params\":[]}")
	//body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
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

func (t Trezarcoin) RPCDefaultUsername() string {
	return cRPCUser
}

func (t Trezarcoin) RPCDefaultPort() string {
	return cRPCPort
}

// func (t *Trezarcoin)GetNetworkBlocksTxtTrezarcoin(bci *models.TZCBlockchainInfo) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if bci.Result.Blocks > 100 {
// 		return "Blocks:      [" + blocksStr + "](fg:green)"
// 	} else {
// 		return "[Blocks:      " + blocksStr + "](fg:red)"
// 	}
// }

// func GetNetworkConnectionsTxtTZC(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

// func GetBlockchainSyncTxtTrezarcoin(synced bool, bci *models.TZCBlockchainInfo) string {
// 	s := ConvertBCVerification(bci.Result.Verificationprogress)
// 	if s == "0.0" {
// 		s = ""
// 	} else {
// 		s = s + "%"
// 	}

// 	if !synced {
// 		if bci.Result.Verificationprogress > gLastBCSyncPos {
// 			gLastBCSyncPos = bci.Result.Verificationprogress
// 			return "Blockchain:  [syncing " + s + " ](fg:yellow)"
// 		} else {
// 			gLastBCSyncPos = bci.Result.Verificationprogress
// 			return "Blockchain:  [waiting " + s + " ](fg:yellow)"
// 		}
// 	} else {
// 		return "Blockchain:  [synced " + CUtfTickBold + "](fg:green)"
// 	}
// }

// func GetNetworkDifficultyTxtTrezarcoin(difficulty, good, warn float64) string {
// 	var s string
// 	if difficulty > 1000 {
// 		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
// 	} else {
// 		s = humanize.Ftoa(difficulty)
// 	}
// 	if difficulty >= good {
// 		return "Difficulty:  [" + s + "](fg:green)"
// 	} else if difficulty >= warn {
// 		return "[Difficulty:  " + s + "](fg:yellow)"
// 	} else {
// 		return "[Difficulty:  " + s + "](fg:red)"
// 	}
// }

func (t Trezarcoin) SendToAddress(coinAuth *models.CoinAuth, address string, amount float32) (returnResp models.GenericResponse, err error) {
	var respStruct models.GenericResponse

	sAmount := fmt.Sprintf("%v", amount)

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandSendToAddress + "\",\"params\":[\"" + address + "\"," + sAmount + "]}")
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

func (t Trezarcoin) StakingInfo(auth *models.CoinAuth) (models.TZCStakingInfo, error) {
	var respStruct models.TZCStakingInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getstakinginfo\",\"params\":[]}")
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

func (t Trezarcoin) StartDaemon(displayOutput bool, appFolder string, auth *models.CoinAuth) error {
	b, _ := t.DaemonRunning()
	if b {
		return nil
	}

	if runtime.GOOS == "windows" {
		fp := appFolder + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the trezarcoin daemon...")
		}

		cmdRun := exec.Command(appFolder + cDaemonFileLin)
		stdout, err := cmdRun.StdoutPipe()
		if err != nil {
			return err
		}
		err = cmdRun.Start()
		if err != nil {
			return err
		}

		buf := bufio.NewReader(stdout) // Notice that this is not in a loop
		num := 1
		for {
			line, _, _ := buf.ReadLine()
			if num > 3 {
				os.Exit(0)
			}
			num++
			if string(line) == "Trezarcoin server starting" {
				if displayOutput {
					fmt.Println("Trezarcoin server starting")
				}
				return nil
			} else {
				return errors.New("unable to start Trezarcoin server: " + string(line))
			}
		}
	}

	return nil
}

func (t Trezarcoin) StopDaemon(auth *models.CoinAuth) error {
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

func (t Trezarcoin) TipAddress() string {
	return cTipAddress
}

func (t Trezarcoin) UpdateTickerInfo() (ticker models.TZCTicker, err error) {
	resp, err := http.Get("https://ticker.neist.io/tzc")
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

func (t Trezarcoin) ValidateAddress(ad string) bool {
	// First, work out what the coin type is
	// If the length of the address is not exactly 34 characters...
	if len(ad) != 34 {
		return false
	}
	sFirst := ad[0]

	// 54 = UTF for T
	if sFirst != 54 {
		return false
	}

	return true
}

func (t Trezarcoin) WalletAddress(auth *models.CoinAuth) (string, error) {
	var sAddress string
	addresses, _ := t.ListReceivedByAddress(auth, true)
	if len(addresses.Result) > 0 {
		sAddress = addresses.Result[0].Address
	} else {
		r, err := t.NewAddress(auth)
		if err != nil {
			return "", err
		}
		sAddress = r.Result
	}

	return sAddress, nil
}

func (t Trezarcoin) WalletBackup(coinAuth *models.CoinAuth, destDir string) (models.GenericResponse, error) {
	var respStruct models.GenericResponse

	destDir = fileutils.AddTrailingSlash(destDir)
	dt := time.Now()
	destFile := dt.Format("2006-01-02") + "-" + cCoinNameAbbrev + "-wallet.dat"

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandBackupWallet + "\",\"params\":[\"" + destDir + destFile + "\"]}")

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

	if respStruct.Error != nil {
		return respStruct, errors.New(fmt.Sprintf("%v", respStruct.Error))
	}

	return respStruct, nil
}

func (t Trezarcoin) WalletEncrypt(coinAuth *models.CoinAuth, pw string) (models.GenericResponse, error) {
	var respStruct models.GenericResponse

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

func (t *Trezarcoin) WalletInfo(auth *models.CoinAuth) (models.TZCWalletInfo, error) {
	var respStruct models.TZCWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getwalletinfo\",\"params\":[]}")
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

	// Check to see if the json response contains "unlocked_until"
	s := string([]byte(bodyResp))
	if !strings.Contains(s, "unlocked_until") {
		respStruct.Result.UnlockedUntil = -1
	}

	return respStruct, nil
}

func (t Trezarcoin) WalletLoadingStatus(auth *models.CoinAuth) models.WLSType {
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
		if bytes.Contains(bodyResp, []byte("RPC in warm-up")) {
			return models.WLSTRPCInWarmUp
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

func (t Trezarcoin) WalletNeedsEncrypting(coinAuth *models.CoinAuth) (bool, error) {
	wi, err := t.WalletInfo(coinAuth)
	if err != nil {
		return true, errors.New("Unable to perform WalletInfo " + err.Error())
	}

	if wi.Result.UnlockedUntil == -1 {
		return true, nil
	}

	return false, nil
}

func (t Trezarcoin) WalletResync(appFolder string) error {
	daemonRunning, err := t.DaemonRunning()
	if err != nil {
		return errors.New("Unable to determine DaemonRunning: " + err.Error())
	}
	if daemonRunning {
		return errors.New("daemon is still running, please stop first")
	}

	arg1 := "-resync"

	if runtime.GOOS == "windows" {
		fullPath := appFolder + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fullPath, arg1)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		fullPath := appFolder + cDaemonFileLin
		cmdRun := exec.Command(fullPath, arg1)
		if err := cmdRun.Run(); err != nil {
			return err
		}
	}

	return nil
}

func (t Trezarcoin) WalletSecurityState(coinAuth *models.CoinAuth) (models.WEType, error) {
	wi, err := t.WalletInfo(coinAuth)
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

func (t Trezarcoin) WalletUnlock(coinAuth *models.CoinAuth, pw string) error {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0]}")
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

func (t Trezarcoin) WalletUnlockFS(coinAuth *models.CoinAuth, pw string) error {
	var respStruct models.GenericResponse
	var body *strings.Reader

	body = strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",9999999,true]}")

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

	if respStruct.Error != nil {
		return errors.New(fmt.Sprintf("%v", respStruct.Error))
	}

	return nil
}

func (t Trezarcoin) unarchiveFile(fullFilePath, location string) error {
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
			defer os.RemoveAll(location + cDownloadFileLin64)
		}
	}

	defer os.Remove(fullFilePath)

	return nil
}
