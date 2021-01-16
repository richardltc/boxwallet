package bend

import (
	"bytes"
	"encoding/json"
	"github.com/dustin/go-humanize"
	"io/ioutil"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	CCoinNameTrezarcoin string = "Trezarcoin"

	CTrezarcoinCoreVersion string = "2.1.3"
	CDFTrezarcoinRPi       string = CTrezarcoinCoreVersion + "-rpi.zip"
	CDFTrezarcoinLinux     string = "trezarcoin-" + CTrezarcoinCoreVersion + "-linux64.tar.gz"
	CDFTrezarcoinWindows   string = "trezarcoin-" + CTrezarcoinCoreVersion + "-win64-setup.exe"

	CTrezarcoinLinuxExtractedDir = "trezarcoin-" + CTrezarcoinCoreVersion + "/"
	CTrezarcoinRPiExtractedDir   = CTrezarcoinCoreVersion + "-rpi/"

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
	cTrezarcoinRPCUser string = "trezarcoinrpc"
	CTrezarcoinRPCPort string = "17299"
)

type TrezarcoinBlockchainInfoRespStruct struct {
	Result struct {
		Chain                string  `json:"chain"`
		Blocks               int     `json:"blocks"`
		Headers              int     `json:"headers"`
		Bestblockhash        string  `json:"bestblockhash"`
		Difficulty           float64 `json:"difficulty"`
		Mediantime           int     `json:"mediantime"`
		Verificationprogress float64 `json:"verificationprogress"`
		Chainwork            string  `json:"chainwork"`
		Pruned               bool    `json:"pruned"`
		Softforks            []struct {
			ID      string `json:"id"`
			Version int    `json:"version"`
			Enforce struct {
				Status   bool `json:"status"`
				Found    int  `json:"found"`
				Required int  `json:"required"`
				Window   int  `json:"window"`
			} `json:"enforce"`
			Reject struct {
				Status   bool `json:"status"`
				Found    int  `json:"found"`
				Required int  `json:"required"`
				Window   int  `json:"window"`
			} `json:"reject"`
		} `json:"softforks"`
		Bip9Softforks struct {
			Csv struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"csv"`
			Segwit struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"segwit"`
		} `json:"bip9_softforks"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}
type trezarcoinInfoRespStruct struct {
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

type TrezarcoinListReceivedByAddressRespStruct struct {
	Result []struct {
		Address       string   `json:"address"`
		Account       string   `json:"account"`
		Amount        float64  `json:"amount"`
		Confirmations int      `json:"confirmations"`
		Label         string   `json:"label"`
		Txids         []string `json:"txids"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type TZCListTransactionsRespStruct struct {
	Result []struct {
		Account           string        `json:"account"`
		Address           string        `json:"address"`
		Category          string        `json:"category"`
		Amount            float64       `json:"amount"`
		CanStake          bool          `json:"canStake"`
		CanSpend          bool          `json:"canSpend"`
		Label             string        `json:"label"`
		Vout              int           `json:"vout"`
		Confirmations     int           `json:"confirmations"`
		Blockhash         string        `json:"blockhash"`
		Blockindex        int           `json:"blockindex"`
		Blocktime         int           `json:"blocktime"`
		Txid              string        `json:"txid"`
		Walletconflicts   []interface{} `json:"walletconflicts"`
		Time              int           `json:"time"`
		TxComment         string        `json:"tx-comment"`
		Timereceived      int           `json:"timereceived"`
		Bip125Replaceable string        `json:"bip125-replaceable"`
		Generated         bool          `json:"generated,omitempty"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type TrezarcoinStakingInfoRespStruct struct {
	Result struct {
		Enabled          bool    `json:"enabled"`
		Staking          bool    `json:"staking"`
		Errors           string  `json:"errors"`
		Currentblocksize int     `json:"currentblocksize"`
		Currentblocktx   int     `json:"currentblocktx"`
		Difficulty       float64 `json:"difficulty"`
		SearchInterval   int     `json:"search-interval"`
		Weight           int64   `json:"weight"`
		Netstakeweight   int64   `json:"netstakeweight"`
		Stakemintime     int     `json:"stakemintime"`
		Stakeminvalue    float64 `json:"stakeminvalue"`
		Stakecombine     float64 `json:"stakecombine"`
		Stakesplit       float64 `json:"stakesplit"`
		Expectedtime     int     `json:"expectedtime"`
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

func GetBlockchainInfoTrezarcoin(cliConf *ConfStruct) (TrezarcoinBlockchainInfoRespStruct, error) {
	var respStruct TrezarcoinBlockchainInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
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

func GetInfoTrezarcoin(cliConf *ConfStruct) (trezarcoinInfoRespStruct, error) {
	//attempts := 5
	//waitingStr := "Checking server..."

	var respStruct trezarcoinInfoRespStruct

	for i := 1; i < 50; i++ {
		//fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
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

		//s := string(bodyResp)
		//AddToLog(lf,s,false)
		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again..
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

func GetNetworkBlocksTxtTrezarcoin(bci *TrezarcoinBlockchainInfoRespStruct) string {
	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

	if bci.Result.Blocks > 100 {
		return "Blocks:      [" + blocksStr + "](fg:green)"
	} else {
		return "[Blocks:      " + blocksStr + "](fg:red)"
	}
}

func GetNetworkConnectionsTxtTZC(connections int) string {
	if connections == 0 {
		return "Peers:       [0](fg:red)"
	}
	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
}

func GetBlockchainSyncTxtTrezarcoin(synced bool, bci *TrezarcoinBlockchainInfoRespStruct) string {
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

func GetNetworkDifficultyTxtTrezarcoin(difficulty, good, warn float64) string {
	var s string
	if difficulty > 1000 {
		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
	} else {
		s = humanize.Ftoa(difficulty)
	}
	if difficulty >= good {
		return "Difficulty:  [" + s + "](fg:green)"
	} else if difficulty >= warn {
		return "[Difficulty:  " + s + "](fg:yellow)"
	} else {
		return "[Difficulty:  " + s + "](fg:red)"
	}
}

func GetStakingInfoTrezarcoin(cliConf *ConfStruct) (TrezarcoinStakingInfoRespStruct, error) {
	var respStruct TrezarcoinStakingInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getstakinginfo\",\"params\":[]}")
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

func GetWalletSecurityStateTrezarcoin(wi *TrezarcoinWalletInfoRespStruct) WEType {
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

func ListReceivedByAddressTrezarcoin(cliConf *ConfStruct, includeZero bool) (TrezarcoinListReceivedByAddressRespStruct, error) {
	var respStruct TrezarcoinListReceivedByAddressRespStruct

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

func ListTranactionsTZC(cliConf *ConfStruct) (TZCListTransactionsRespStruct, error) {
	var respStruct TZCListTransactionsRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"listtransactions\",\"params\":[]}")
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
