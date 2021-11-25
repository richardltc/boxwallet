package reddcoin

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
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"runtime"
	"strings"
	"time"

	"github.com/mholt/archiver"
	"github.com/theckman/yacspin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "ReddCoin"
	cCoinNameAbbrev string = "RDD"

	cCoinCoreVersion string = "3.10.3"

	cDownloadFileArm32 = "reddcoin-" + cCoinCoreVersion + "-armhf.zip"
	//cDownloadFileLin32 string = "reddcoin-" + cCoinCoreVersion + "-linux32.tar.gz"
	cDownloadFileLin64 string = "reddcoin-" + cCoinCoreVersion + "-linux64.tar.gz"
	cDownloadFileWin   string = "reddcoin-" + cCoinCoreVersion + "-win64.zip"
	cDownloadFileBS    string = "blockchain-latest.zip"

	cExtractedDirLin = "reddcoin-" + cCoinCoreVersion + "/"
	//cExtractedDirWin = "reddcoin-" + cCoinCoreVersion + "\\"

	cDownloadURL    string = "https://download.reddcoin.com/bin/reddcoin-core-" + cCoinCoreVersion + "/"
	cDownloadURLArm string = "https://sourceforge.net/projects/reddpi/files/update/reddcoin-" + cCoinCoreVersion + "-armhf.zip/download"
	cDownloadURLBS  string = "https://download.reddcoin.com/bin/bootstrap/"

	cHomeDirLin string = ".reddcoin"
	cHomeDirWin string = "REDDCOIN"

	cConfFile      string = "reddcoin.conf"
	cCliFileLin    string = "reddcoin-cli"
	cCliFileWin    string = "reddcoin-cli.exe"
	cDaemonFileLin string = "reddcoind"
	cDaemonFileWin string = "reddcoind.exe"
	cTxFileLin     string = "reddcoin-tx"
	cTxFileWin     string = "reddcoin-tx.exe"

	cMinTXFee float64 = 0.004

	cTipAddress string = "RtH6nZvmnstUsy5w5cmdwTrarbTPm6zyrC"

	cRPCUser string = "reddcoinrpc"
	cRPCPort string = "45443"
)

type ReddCoin struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (r ReddCoin) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	r.RPCUser = rpcUser
	r.RPCPassword = rpcPassword
	r.IPAddress = ip
	r.Port = port
}

func (ReddCoin) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (ReddCoin) AllBinaryFilesExist(dir string) (bool, error) {
	if runtime.GOOS == "windows" {
		if !fileExists(dir + cCliFileWin) {
			return false, nil
		}
		if !fileExists(dir + cDaemonFileWin) {
			return false, nil
		}
		if !fileExists(dir + cTxFileWin) {
			return false, nil
		}
	} else {
		if !fileExists(dir + cCliFileLin) {
			return false, nil
		}
		if !fileExists(dir + cDaemonFileLin) {
			return false, nil
		}
		if !fileExists(dir + cTxFileLin) {
			return false, nil
		}
	}
	return true, nil
}

// BlockchainDataExists - Returns true if the Blockchain data exists for the specified coin.
func (r ReddCoin) BlockchainDataExists() (bool, error) {
	coinDir, err := r.HomeDirFullPath()
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

func (r ReddCoin) BlockchainInfo(auth *models.CoinAuth) (models.RDDBlockchainInfo, error) {
	var respStruct models.RDDBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetBCInfo + "\",\"params\":[]}")
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
func (r ReddCoin) BlockchainIsSynced(coinAuth *models.CoinAuth) (bool, error) {
	bci, err := r.BlockchainInfo(coinAuth)
	if err != nil {
		return false, err
	}

	if bci.Result.Verificationprogress > 0.99999 {
		return true, nil
	}

	return false, nil
}

func (r ReddCoin) ConfFile() string {
	return cConfFile
}

func (r ReddCoin) CoinName() string {
	return cCoinName
}

func (r ReddCoin) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (r ReddCoin) DaemonRunning() (bool, error) {
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

func (r ReddCoin) DownloadBlockchain() error {
	coinDir, err := r.HomeDirFullPath()
	if err != nil {
		return errors.New("unable to get HomeDirFullPath: " + err.Error())
	}
	bcsFileExists := fileutils.FileExists(coinDir + cDownloadFileBS)
	if !bcsFileExists {
		// Then download the file.
		if err := rjminternet.DownloadFile(coinDir, cDownloadURLBS+cDownloadFileBS); err != nil {
			return fmt.Errorf("unable to download file: %v - %v", cDownloadURLBS, err)
		}
	}
	return nil
}

// DownloadCoin - Downloads the Syscoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (r ReddCoin) DownloadCoin(location string) error {
	var fullFilePath, fullFileDLURL string

	switch runtime.GOOS {
	case "windows":
		fullFilePath = location + cDownloadFileWin
		fullFileDLURL = cDownloadURL + cDownloadFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			fullFilePath = location + cDownloadFileArm32
			fullFileDLURL = cDownloadURLArm + cDownloadFileArm32
		case "arm64":
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			fullFilePath = location + cDownloadFileLin64
			fullFileDLURL = cDownloadURL + cDownloadFileLin64
		}
	}

	if err := rjminternet.DownloadFile(fullFilePath, fullFileDLURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", fullFilePath+fullFileDLURL, err)
	}

	// Unarchive the files
	if err := r.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}
	return nil
}

func (r ReddCoin) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	} else {
		return cDaemonFileLin
	}
}

// func (r *ReddCoin)GetBlockchainSyncTxtRDD(synced bool, bci *models.RDDBlockchainInfo) string {
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

func (r *ReddCoin) Info() (models.RDDGetInfo, error) {
	//attempts := 5
	//waitingStr := "Checking server.."

	var respStruct models.RDDGetInfo

	for i := 1; i < 50; i++ {
		//fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+r.IPAddress+":"+r.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(r.RPCUser, r.RPCPassword)
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
			var errStruct models.GenericResponse
			err = json.Unmarshal(bodyResp, &errStruct)
			if err != nil {
				return respStruct, err
			}
			//fmt.Println("Waiting for wallet to load...")
			time.Sleep(5 * time.Second)
		} else {

			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
}

func (r *ReddCoin) InfoUI(spin *yacspin.Spinner) (models.RDDGetInfo, string, error) {
	var respStruct models.RDDGetInfo

	for i := 1; i < 600; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+r.IPAddress+":"+r.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(r.RPCUser, r.RPCPassword)
		req.Header.Set("Content-Type", "text/plain;")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			spin.Message(" waiting for your " + cCoinName + " wallet to respond, this could take several minutes (ctrl-c to cancel)...")
			time.Sleep(1 * time.Second)
		} else {
			defer resp.Body.Close()
			bodyResp, err := ioutil.ReadAll(resp.Body)
			if err != nil {
				return respStruct, "", err
			}

			// Check to make sure we are not loading the wallet.
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

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (r ReddCoin) Install(location string) error {

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

	// If the cointx file doesn't already exists the copy it.
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

// func (r *ReddCoin)GetNetworkBlocksTxtRDD(bci *models.RDDBlockchainInfo) string {
// 	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

// 	if blocksStr == "0" {
// 		return "Blocks:      [waiting...](fg:white)"
// 	}

// 	return "Blocks:      [" + blocksStr + "](fg:green)"

// }

// func GetNetworkConnectionsTxtRDD(connections int) string {
// 	if connections == 0 {
// 		return "Peers:       [0](fg:red)"
// 	}
// 	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
// }

// func GetNetworkDifficultyTxtRDD(difficulty, good, warn float64) string {
// 	var s string
// 	if difficulty > 1000 {
// 		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
// 	} else {
// 		s = humanize.Ftoa(difficulty)
// 	}

// 	// If Diff is less than 1, then we're not even calculating it properly yet..
// 	if difficulty < 1 {
// 		return "[Difficulty:  waiting...](fg:white)"
// 	}

// 	if difficulty >= good {
// 		return "Difficulty:  [" + s + "](fg:green)"
// 	} else if difficulty >= warn {
// 		return "Difficulty:  [" + s + "](fg:yellow)"
// 	} else {
// 		return "Difficulty:  [" + s + "](fg:red)"
// 	}
// }

// func GetNetworkHeadersTxtRDD(bci *models.RDDBlockchainInfo) string {
// 	headersStr := humanize.Comma(int64(bci.Result.Headers))

// 	if bci.Result.Headers > 1 {
// 		return "Headers:     [" + headersStr + "](fg:green)"
// 	} else {
// 		return "[Headers:     " + headersStr + "](fg:red)"
// 	}
// }

func (r *ReddCoin) NetworkInfo(auth *models.CoinAuth) (models.RDDNetworkInfo, error) {
	var respStruct models.RDDNetworkInfo

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

func (r ReddCoin) RPCDefaultUsername() string {
	return cRPCUser
}

func (r ReddCoin) RPCDefaultPort() string {
	return cRPCPort
}

func (r ReddCoin) WalletInfo(auth *models.CoinAuth) (models.RDDWalletInfo, error) {
	var respStruct models.RDDWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetWalletInfo + "\",\"params\":[]}")
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
	s := string(bodyResp)
	if !strings.Contains(s, "unlocked_until") {
		respStruct.Result.UnlockedUntil = -1
	}

	return respStruct, nil
}

func (r ReddCoin) WalletSecurityState(coinAuth *models.CoinAuth) (models.WEType, error) {
	wi, err := r.WalletInfo(coinAuth)
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

func (r ReddCoin) HomeDirFullPath() (string, error) {
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

func (r ReddCoin) ListReceivedByAddress(coinAuth *models.CoinAuth, includeZero bool) (models.RDDListReceivedByAddress, error) {
	var respStruct models.RDDListReceivedByAddress

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

func (r *ReddCoin) ListTransactions(auth *models.CoinAuth) (models.RDDListTransactions, error) {
	var respStruct models.RDDListTransactions

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

func (r ReddCoin) NewAddress(auth *models.CoinAuth) (models.RDDGetNewAddress, error) {
	var respStruct models.RDDGetNewAddress

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
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

func (r ReddCoin) SendToAddress(coinAuth *models.CoinAuth, address string, amount float32) (returnResp models.GenericResponse, err error) {
	var respStruct models.GenericResponse

	_, _ = setTXFee(coinAuth)

	//sAmount := fmt.Sprintf("%f.8", amount)
	sAmount := fmt.Sprintf("%v", amount)

	//sAmount := strconv.FormatFloat(amount,'E',-1,//fmt.Sprintf("%f", amount) // sAmount == "123.456000"
	//sMinFee := strconv.FormatFloat(cMinTXFee,'E',-1,64) //fmt.Sprintf("%f", cMinTXFee)

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

func setTXFee(coinAuth *models.CoinAuth) (returnResp models.GenericResponse, err error) {
	var respStruct models.GenericResponse

	sMinFee := fmt.Sprintf("%v", cMinTXFee)

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandSetTxFee + "\",\"params\":[" + sMinFee + "]}")
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

func (r ReddCoin) StartDaemon(displayOutput bool, appFolder string, auth *models.CoinAuth) error {
	b, _ := r.DaemonRunning()
	if b {
		return nil
	}

	if runtime.GOOS == "windows" {
		//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
		fp := appFolder + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the reddcoin daemon...")
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

		buf := bufio.NewReader(stdout)
		num := 1
		for {
			line, _, _ := buf.ReadLine()
			if num > 3 {
				os.Exit(0)
			}
			num++
			if string(line) == "Reddcoin server starting" {
				if displayOutput {
					fmt.Println("Reddcoin server starting")
				}
				return nil
			} else {
				fmt.Println("Have you installed these dependencies?\n\nlibssl1.0-dev libprotobuf17 libboost-thread1.62-dev libboost-program-options1.62-dev libboost-filesystem1.62-dev libboost-system1.62-dev")
				return errors.New("unable to start the Reddcoin server: " + string(line))
			}
		}

	}
	return nil
}

func (r ReddCoin) StopDaemon(auth *models.CoinAuth) error {
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

	return nil
}

func (r ReddCoin) TipAddress() string {
	return cTipAddress
}

func (r ReddCoin) UnarchiveBlockchainSnapshot() error {
	coinDir, err := r.HomeDirFullPath()
	if err != nil {
		return errors.New("unable to get HomeDirFul - " + err.Error())
	}

	// First, check to make sure that both the blockchain folders don't already exist. (blocks, chainstate)
	bcsFileExists := fileutils.FileExists(coinDir + cDownloadFileBS)
	if !bcsFileExists {
		return errors.New("unable to find the snapshot file: " + coinDir + cDownloadFileBS)
	}

	// Now extract it straight into the ~/.reddcoin folder
	if err := archiver.Unarchive(coinDir+cDownloadFileBS, coinDir); err != nil {
		return errors.New("unable to unarchive file: " + coinDir + cDownloadFileBS + " " + err.Error())
	}
	return nil
}

func (r *ReddCoin) UnlockWallet(pw string) error {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0]}")
	req, err := http.NewRequest("POST", "http://"+r.IPAddress+":"+r.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(r.RPCUser, r.RPCPassword)
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

func (r ReddCoin) UpdateTickerInfo() (ticker models.RDDTicker, err error) {
	resp, err := http.Get("https://ticker.neist.io/RDD")
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

func (r ReddCoin) ValidateAddress(ad string) bool {
	// First, work out what the coin type is
	// If the length of the address is not exactly 34 characters...
	if len(ad) != 34 {
		return false
	}
	sFirst := ad[0]

	// 82 = UTF for R
	if sFirst != 82 {
		return false
	}
	return true
}

func (r ReddCoin) WalletAddress(auth *models.CoinAuth) (string, error) {
	var sAddress string
	addresses, _ := r.ListReceivedByAddress(auth, true)
	if len(addresses.Result) > 0 {
		sAddress = addresses.Result[0].Address
	} else {
		res, err := r.NewAddress(auth)
		if err != nil {
			return "", err
		}
		sAddress = res.Result
	}
	return sAddress, nil
}

func (r ReddCoin) WalletEncrypt(coinAuth *models.CoinAuth, pw string) (be.GenericRespStruct, error) {
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

func (r ReddCoin) WalletNeedsEncrypting(coinAuth *models.CoinAuth) (bool, error) {
	wi, err := r.WalletInfo(coinAuth)
	if err != nil {
		return true, errors.New("Unable to perform WalletInfo " + err.Error())
	}

	if wi.Result.UnlockedUntil == -1 {
		return true, nil
	}

	return false, nil
}

func (r ReddCoin) WalletLoadingStatus(auth *models.CoinAuth) models.WLSType {
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

func (r ReddCoin) WalletResync(appFolder string) error {
	daemonRunning, err := r.DaemonRunning()
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

func (r ReddCoin) WalletUnlock(coinAuth *models.CoinAuth, pw string) error {
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

func (r ReddCoin) WalletUnlockFS(coinAuth *models.CoinAuth, pw string) error {
	var respStruct be.GenericRespStruct
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
	if err != nil || respStruct.Error != nil {
		return err
	}
	return nil
}

func fileExists(filename string) bool {
	info, err := os.Stat(filename)
	if os.IsNotExist(err) {
		return false
	}
	return !info.IsDir()
}

func (r *ReddCoin) unarchiveFile(fullFilePath, location string) error {
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
