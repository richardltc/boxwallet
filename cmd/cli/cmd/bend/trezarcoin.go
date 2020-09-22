package bend

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	CCoinNameTrezarcoin string = "Trezarcoin"

	CTrezarcoinCoreVersion string = "2.1.1"
	CDFTrezarcoinRPi       string = "Trezarcoin-" + CTrezarcoinCoreVersion + "-rPI.zip"
	CDFTrezarcoinLinux     string = "trezarcoin-" + CTrezarcoinCoreVersion + "-x86_64-linux-gnu.tar.gz"
	CDFTrezarcoinWindows   string = "trezarcoin-" + CTrezarcoinCoreVersion + "-win64-setup.exe"

	CTrezarcoinExtractedDir = "trezarcoin-" + CTrezarcoinCoreVersion + "/"

	CDownloadURLTC string = "https://github.com/TrezarCoin/TrezarCoin/releases/download/v" + CTrezarcoinCoreVersion + ".0/"

	CTrezarcoinHomeDir    string = ".trezarcoin"
	CTrezarcoinHomeDirWin string = "TREZARCOIN"

	CTrezarcoinConfFile   string = "trezarcoin.conf"
	CTrezarcoinCliFile    string = "trezarcoin-cli"
	CTrezarcoinCliFileWin string = "trezarcoin-cli.exe"
	CTrezarcoinDFile      string = "trezarcoind"
	CTrezarcoinDFileWin   string = "trezarcoind.exe"
	CTrezarcoinTxFile     string = "trezarcoin-tx"
	CTrezarcoinTxFileWin  string = "trezarcoin-tx.exe"

	// trezarcoin.conf file constants
	CTrezarcoinRPCPort string = "17299"
)

type trezarcoinGetInfoRespStruct struct {
	Result struct {
		Version            int     `json:"version"`
		Protocolversion    int     `json:"protocolversion"`
		Walletversion      int     `json:"walletversion"`
		Balance            float64 `json:"balance"`
		ColdstakingBalance float64 `json:"coldstaking_balance"`
		Newmint            float64 `json:"newmint"`
		Stake              float64 `json:"stake"`
		Blocks             int     `json:"blocks"`
		Moneysupply        float64 `json:"moneysupply"`
		Timeoffset         int     `json:"timeoffset"`
		Connections        int     `json:"connections"`
		Proxy              string  `json:"proxy"`
		Difficulty         struct {
			ProofOfWork  float64 `json:"proof-of-work"`
			ProofOfStake float64 `json:"proof-of-stake"`
		} `json:"difficulty"`
		Testnet       bool    `json:"testnet"`
		Keypoololdest int     `json:"keypoololdest"`
		Keypoolsize   int     `json:"keypoolsize"`
		UnlockedUntil int     `json:"unlocked_until"`
		Paytxfee      float64 `json:"paytxfee"`
		Relayfee      float64 `json:"relayfee"`
		Errors        string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type TrezarcoinWalletInfoRespStruct struct {
	Result struct {
		Walletversion      int     `json:"walletversion"`
		Balance            float64 `json:"balance"`
		ColdstakingBalance float64 `json:"coldstaking_balance"`
		UnconfirmedBalance float64 `json:"unconfirmed_balance"`
		ImmatureBalance    float64 `json:"immature_balance"`
		Txcount            int     `json:"txcount"`
		Keypoololdest      int     `json:"keypoololdest"`
		Keypoolsize        int     `json:"keypoolsize"`
		UnlockedUntil      int     `json:"unlocked_until"`
		Paytxfee           float64 `json:"paytxfee"`
		Hdmasterkeyid      string  `json:"hdmasterkeyid"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

func GetInfoTrezarcoin(cliConf *ConfStruct) (trezarcoinGetInfoRespStruct, error) {
	attempts := 5
	waitingStr := "Checking server..."

	var respStruct trezarcoinGetInfoRespStruct

	for i := 1; i < 50; i++ {
		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"getinfo\",\"params\":[]}")
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
		if bytes.Contains(bodyResp, []byte("Loading")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again...
			var errStruct GenericRespStruct
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

func GetWalletInfoTrezarcoin(cliConf *ConfStruct) (TrezarcoinWalletInfoRespStruct, error) {
	var respStruct TrezarcoinWalletInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getwalletinfo\",\"params\":[]}")
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
