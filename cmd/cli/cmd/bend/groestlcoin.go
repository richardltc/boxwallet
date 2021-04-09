package bend

import (
	"bytes"
	"encoding/json"
	"io/ioutil"
	"net/http"
	"strings"
	"time"
)

const (
	CCoinNameGroestlcoin   string = "Groestlcoin"
	CCoinAbbrevGroestlcoin string = "GRS"

	CCoreVersionGroestlcoin string = "2.21.0"
	CDFRPiGroestlcoin       string = "groestlcoin-" + CCoreVersionGroestlcoin + "-arm-linux-gnueabihf.tar.gz"
	CDFLinuxGroestlcoin     string = "groestlcoin-" + CCoreVersionGroestlcoin + "-x86_64-linux-gnu.tar.gz"
	CDFWindowsGroestlcoin   string = "groestlcoin-" + CCoreVersionGroestlcoin + "-win64.zip"

	CExtractedDirLinuxGroestlcoin   = "groestlcoin-" + CCoreVersionGroestlcoin + "/"
	CExtractedDirWindowsGroestlcoin = "groestlcoin-" + CCoreVersionGroestlcoin + "\\"

	CDownloadURLGroestlcoin string = "https://github.com/Groestlcoin/groestlcoin/releases/download/v" + CCoreVersionGroestlcoin + "/"

	cHomeDirGroestlcoin    string = ".groestlcoin"
	cHomeDirWinGroestlcoin string = "GROESTLCOIN"

	// Files
	cConfFileGroestlcoin   string = "groestlcoin.conf"
	CCliFileGroestlcoin    string = "groestlcoin-cli"
	CCliFileWinGroestlcoin string = "groestlcoin-cli.exe"
	CDFileGroestlcoin      string = "groestlcoind"
	CDFileWinGroestlcoin   string = "groestlcoind.exe"
	CTxFileGroestlcoin     string = "groestlcoin-tx"
	CTxFileWinGroestlcoin  string = "groestlcoin-tx.exe"

	// Networking
	cRPCUserGroestlcoin string = "groestlcoinrpc"
	CRPCPortGroestlcoin string = "1441"
)

type GRSBlockchainInfoRespStruct struct {
	Result struct {
		Chain                string  `json:"chain"`
		Blocks               int     `json:"blocks"`
		Headers              int     `json:"headers"`
		Bestblockhash        string  `json:"bestblockhash"`
		Difficulty           float64 `json:"difficulty"`
		Mediantime           int     `json:"mediantime"`
		Verificationprogress float64 `json:"verificationprogress"`
		Initialblockdownload bool    `json:"initialblockdownload"`
		Chainwork            string  `json:"chainwork"`
		SizeOnDisk           int     `json:"size_on_disk"`
		Pruned               bool    `json:"pruned"`
		Softforks            struct {
			Bip34 struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"bip34"`
			Bip66 struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"bip66"`
			Bip65 struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"bip65"`
			Csv struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"csv"`
			Segwit struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"segwit"`
		} `json:"softforks"`
		Warnings string `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type GRSListReceivedByAddressRespStruct struct {
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

type GRSNetworkInfoRespStruct struct {
	Result struct {
		Version            int      `json:"version"`
		Subversion         string   `json:"subversion"`
		Protocolversion    int      `json:"protocolversion"`
		Localservices      string   `json:"localservices"`
		Localservicesnames []string `json:"localservicesnames"`
		Localrelay         bool     `json:"localrelay"`
		Timeoffset         int      `json:"timeoffset"`
		Networkactive      bool     `json:"networkactive"`
		Connections        int      `json:"connections"`
		Networks           []struct {
			Name                      string `json:"name"`
			Limited                   bool   `json:"limited"`
			Reachable                 bool   `json:"reachable"`
			Proxy                     string `json:"proxy"`
			ProxyRandomizeCredentials bool   `json:"proxy_randomize_credentials"`
		} `json:"networks"`
		Relayfee       float64       `json:"relayfee"`
		Incrementalfee float64       `json:"incrementalfee"`
		Localaddresses []interface{} `json:"localaddresses"`
		Warnings       string        `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type GRSNewAddressStruct struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type GRSWalletInfoRespStruct struct {
	Result struct {
		Walletname            string  `json:"walletname"`
		Walletversion         int     `json:"walletversion"`
		Balance               float64 `json:"balance"`
		UnconfirmedBalance    float64 `json:"unconfirmed_balance"`
		ImmatureBalance       float64 `json:"immature_balance"`
		Txcount               int     `json:"txcount"`
		Keypoololdest         int     `json:"keypoololdest"`
		Keypoolsize           int     `json:"keypoolsize"`
		Hdseedid              string  `json:"hdseedid"`
		KeypoolsizeHdInternal int     `json:"keypoolsize_hd_internal"`
		Paytxfee              float64 `json:"paytxfee"`
		PrivateKeysEnabled    bool    `json:"private_keys_enabled"`
		AvoidReuse            bool    `json:"avoid_reuse"`
		Scanning              bool    `json:"scanning"`
		UnlockedUntil         int     `json:"unlocked_until"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

func GetBlockchainInfoGRS(cliConf *ConfStruct) (GRSBlockchainInfoRespStruct, error) {
	var respStruct GRSBlockchainInfoRespStruct

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

func GetNewAddressGRS(cliConf *ConfStruct) (GRSNewAddressStruct, error) {
	var respStruct GRSNewAddressStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
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

func GetWalletInfoGRS(cliConf *ConfStruct) (GRSWalletInfoRespStruct, error) {
	var respStruct GRSWalletInfoRespStruct

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

func GetNetworkInfoGRS(cliConf *ConfStruct) (GRSNetworkInfoRespStruct, error) {
	var respStruct GRSNetworkInfoRespStruct

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

func GetWalletSecurityStateGRS(wi *GRSWalletInfoRespStruct) WEType {
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

func ListReceivedByAddressGRS(cliConf *ConfStruct, includeZero bool) (GRSListReceivedByAddressRespStruct, error) {
	var respStruct GRSListReceivedByAddressRespStruct

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
