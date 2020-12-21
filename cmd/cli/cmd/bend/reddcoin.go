package bend

import (
	"bytes"
	"encoding/json"
	"github.com/dustin/go-humanize"
	"io/ioutil"
	"net/http"
	"strings"
	"time"
)

const (
	CCoinNameReddCoin string = "ReddCoin"

	CReddCoinCoreVersion string = "3.10.3"

	CDFReddCoinRPi     string = "reddcoin-" + CReddCoinCoreVersion + "-arm64.tar.gz"
	CDFReddCoinLinux   string = "reddcoin-" + CReddCoinCoreVersion + "-linux64.tar.gz"
	CDFReddCoinWindows string = "reddcoin-" + CReddCoinCoreVersion + "-win64.zip"

	CReddCoinExtractedDirLinux = "reddcoin-" + CReddCoinCoreVersion + "/"

	CDownloadURLReddCoin string = "https://download.reddcoin.com/bin/reddcoin-core-" + CReddCoinCoreVersion + "/"
	CReddCoinHomeDir     string = ".reddcoin"
	CReddCoinHomeDirWin  string = "REDDCOIN"

	CReddCoinConfFile   string = "reddcoin.conf"
	CReddCoinCliFile    string = "reddcoin-cli"
	CReddCoinCliFileWin string = "reddcoin-cli.exe"
	CReddCoinDFile      string = "reddcoind"
	CReddCoinDFileWin   string = "reddcoind.exe"
	CReddCoinTxFile     string = "reddcoin-tx"
	CReddCoinTxFileWin  string = "reddcoin-tx.exe"

	cReddCoinRPCUser string = "reddcoinrpc"
	CReddCoinRPCPort string = "45443"
)

type RDDBlockchainInfoRespStruct struct {
	Result struct {
		Chain                string  `json:"chain"`
		Blocks               int     `json:"blocks"`
		Headers              int     `json:"headers"`
		Bestblockhash        string  `json:"bestblockhash"`
		Difficulty           float64 `json:"difficulty"`
		Verificationprogress float64 `json:"verificationprogress"`
		Chainwork            string  `json:"chainwork"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

// Might need a live update
type RDDListReceivedByAddressRespStruct struct {
	Result []struct {
		Address       string        `json:"address"`
		Amount        float64       `json:"amount"`
		Confirmations int           `json:"confirmations"`
		Label         string        `json:"label"`
		Txids         []interface{} `json:"txids"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type RDDNetworkInfoRespStruct struct {
	Result struct {
		Version         int    `json:"version"`
		Subversion      string `json:"subversion"`
		Protocolversion int    `json:"protocolversion"`
		Localservices   string `json:"localservices"`
		Timeoffset      int    `json:"timeoffset"`
		Connections     int    `json:"connections"`
		Networks        []struct {
			Name      string `json:"name"`
			Limited   bool   `json:"limited"`
			Reachable bool   `json:"reachable"`
			Proxy     string `json:"proxy"`
		} `json:"networks"`
		Relayfee       float64       `json:"relayfee"`
		Localaddresses []interface{} `json:"localaddresses"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type RDDWalletInfoRespStruct struct {
	Result struct {
		Walletversion int     `json:"walletversion"`
		Balance       float64 `json:"balance"`
		Txcount       int     `json:"txcount"`
		Keypoololdest int     `json:"keypoololdest"`
		UnlockedUntil int     `json:"unlocked_until"`
		Keypoolsize   int     `json:"keypoolsize"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

func GetBlockchainInfoRDD(cliConf *ConfStruct) (RDDBlockchainInfoRespStruct, error) {
	var respStruct RDDBlockchainInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"" + cCommandGetBCInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
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

func GetBlockchainSyncTxtRDD(synced bool, bci *RDDBlockchainInfoRespStruct) string {
	s := ConvertBCVerification(bci.Result.Verificationprogress)
	if s == "0.0" {
		s = ""
	} else {
		s = s + "%"
	}

	if !synced {
		if bci.Result.Verificationprogress > gLastBCSyncPos {
			gLastBCSyncPos = bci.Result.Verificationprogress
			return "Blockchain:  [syncing " + s + " ](fg:yellow)"
		} else {
			gLastBCSyncPos = bci.Result.Verificationprogress
			return "Blockchain:  [waiting " + s + " ](fg:yellow)"
		}
	} else {
		return "Blockchain:  [synced " + CUtfTickBold + "](fg:green)"
	}
}

func GetNetworkBlocksTxtRDD(bci *RDDBlockchainInfoRespStruct) string {
	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

	if blocksStr == "0" {
		return "Blocks:      [waiting...](fg:white)"
	}

	return "Blocks:      [" + blocksStr + "](fg:green)"

}

func GetNetworkDifficultyTxtRDD(difficulty, good, warn float64) string {
	var s string
	if difficulty > 1000 {
		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
	} else {
		s = humanize.Ftoa(difficulty)
	}

	// If Diff is less than 1, then we're not even calculating it properly yet..
	if difficulty < 1 {
		return "[Difficulty:  waiting...](fg:white)"
	}

	if difficulty >= good {
		return "Difficulty:  [" + s + "](fg:green)"
	} else if difficulty >= warn {
		return "Difficulty:  [" + s + "](fg:yellow)"
	} else {
		return "Difficulty:  [" + s + "](fg:red)"
	}
}

func GetNetworkHeadersTxtRDD(bci *RDDBlockchainInfoRespStruct) string {
	headersStr := humanize.Comma(int64(bci.Result.Headers))

	if bci.Result.Headers > 1 {
		return "Headers:     [" + headersStr + "](fg:green)"
	} else {
		return "[Headers:     " + headersStr + "](fg:red)"
	}
}

func GetNetworkInfoRDD(cliConf *ConfStruct) (RDDNetworkInfoRespStruct, error) {
	var respStruct RDDNetworkInfoRespStruct

	for i := 1; i < 50; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnetworkinfo\",\"params\":[]}")

		req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
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
		if bytes.Contains(bodyResp, []byte("Loading")) || bytes.Contains(bodyResp, []byte("Rewinding")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again..
			time.Sleep(5 * time.Second)
		} else {
			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
}

func GetWalletInfoRDD(cliConf *ConfStruct) (RDDWalletInfoRespStruct, error) {
	var respStruct RDDWalletInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\" getwalletinfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
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

func GetWalletSecurityStateRDD(wi *RDDWalletInfoRespStruct) WEType {
	if wi.Result.UnlockedUntil == 0 {
		return WETLocked
	} else if wi.Result.UnlockedUntil == -1 {
		return WETUnencrypted
	} else if wi.Result.UnlockedUntil > 0 {
		return WETUnlockedForStaking
	} else {
		return WETUnknown
	}
}

func ListReceivedByAddressRDD(cliConf *ConfStruct, includeZero bool) (RDDListReceivedByAddressRespStruct, error) {
	var respStruct RDDListReceivedByAddressRespStruct

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
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

func UnlockWalletRDD(cliConf *ConfStruct, pw string) error {
	var respStruct GenericRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
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
