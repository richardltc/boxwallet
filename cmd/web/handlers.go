package main

import (
	"encoding/json"
	"io/ioutil"
	"net/http"
	"os"

	gwc "github.com/richardltc/gwcommon"
	bend "richardmace.co.uk/godivi/cmd/web/bend"
	rand "richardmace.co.uk/godivi/cmd/web/bend/rand"
	"richardmace.co.uk/godivi/pkg/models"
)

func (app *application) home(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		app.notFound(w)
		return
	}

	w.Write([]byte("Hello from GoDivi Server"))
}

func (app *application) serverRequest(w http.ResponseWriter, r *http.Request) {
	if r.Method == "GET" {
		// Respond with appropriate info for a GET Server request.

		var resp struct {
			DiviDRunning   bool   `json: "DiviDRunning"`
			DiviAppVersion string `json: "DiviAppVersion"`
			GoDiviSVer     string `json: "GoDiviSVer"`
		}

		resp.DiviAppVersion = gwc.CDiviAppVersion
		resp.DiviDRunning, _, _ = gwc.IsCoinDaemonRunning()
		resp.GoDiviSVer = gwc.CAppVersion
		bytes, err := json.MarshalIndent(resp, "", "  ")
		if err != nil {
			app.serverError(w, err)
			return
		}
		app.success(w, string(bytes))
	} else {
		var server models.ServerRequestStruct
		reqBody, err := ioutil.ReadAll(r.Body)

		if err != nil {
			app.badRequest(w, "Please use the correct API request for accessing server")
			return
		}

		err = json.Unmarshal(reqBody, &server)
		if err != nil {
			app.serverError(w, err)
			return
		}

		switch server.ServerRequest {
		/*
			GenerateToken
		*/
		case gwc.CServRequestGenerateToken:
			var resp models.TokenResponseStruct

			// Make sure token hasn't already been generated
			srvConf, err := gwc.GetServerConfStruct()
			if err != nil {
				app.serverError(w, err)
				return
			}
			if srvConf.Token != "" {
				resp.Desc = "The token has already been generated."
				bytes, err := json.MarshalIndent(resp, "", "  ")
				if err != nil {
					app.serverError(w, err)
					return
				}
				app.success(w, string(bytes))
				app.infoLog.Println("GenerateToken request detected, but token already generated")
				return
			}

			// It hasn't already been generated so generate it.
			app.infoLog.Println("GenerateToken request detected so generating...")
			sToken := rand.String(8)
			resp.Token = sToken
			srvConf.Token = sToken
			resp.Desc = "Token generated"

			err = gwc.SetServerConfStruct(srvConf)
			if err != nil {
				app.serverError(w, err)
				return
			}

			bytes, err := json.MarshalIndent(resp, "", "  ")
			if err != nil {
				app.serverError(w, err)
				return
			}
			app.success(w, string(bytes))
			app.infoLog.Println("Token generated and returned to caller")
		/*
			ShutdownServer
		*/
		case gwc.CServRequestShutdownServer:
			var resp struct {
				Desc string `json: "Desc"`
			}

			resp.Desc = "Server shutdown request detected, so shutting down"
			bytes, err := json.MarshalIndent(resp, "", "  ")
			if err != nil {
				app.serverError(w, err)
				return
			}
			app.success(w, string(bytes))
			app.infoLog.Println("Server shutdown request detected, so shutting down")
			os.Exit(0)
		default:
			var resp struct {
				Desc string `json: "Desc"`
			}

			resp.Desc = "Unknown request: " + server.ServerRequest
			bytes, err := json.MarshalIndent(resp, "", "  ")
			if err != nil {
				app.badRequest(w, "Unknown request: "+server.ServerRequest)
				return
			}
			app.success(w, string(bytes))
		}

	}

}

func (app *application) walletRequest(w http.ResponseWriter, r *http.Request) {
	var wallet models.WalletStruct
	reqBody, err := ioutil.ReadAll(r.Body)

	if err != nil {
		app.badRequest(w, "Please use the correct API request for accessing wallet")
		return
	}

	err = json.Unmarshal(reqBody, &wallet)
	if err != nil {
		app.serverError(w, err)
		return
	}

	switch wallet.WalletRequest {
	/*
		GetPrivateKey
	*/
	case gwc.CWalletRequestGetPrivateKey:
		app.infoLog.Println(gwc.CWalletRequestGetPrivateKey + " request detected...")
		var resp models.PrivateKeyStruct
		app.infoLog.Println("Attempting to GetPrivateKey...")
		ps, _, err := bend.GetPrivKey()
		if err != nil {
			// We did not get a response within the time frame, so return
			app.infoLog.Println("No response from coin daemon, so returning to caller")
			resp.ResponseCode = gwc.WalletDidNotRespondInTime
			bytes, err := json.MarshalIndent(resp, "", "  ")
			if err != nil {
				app.serverError(w, err)
				return
			}
			app.success(w, string(bytes))
			return
		}
		app.infoLog.Println("PrivateKey received")
		resp.Hdseed = ps.Hdseed
		resp.Mnemonic = ps.Mnemonic
		resp.ResponseCode = gwc.NoServerError

		bytes, err := json.MarshalIndent(resp, "", "  ")
		if err != nil {
			app.serverError(w, err)
			return
		}
		app.infoLog.Println("Returning PrivateSeed to caller...")
		app.success(w, string(bytes))
		/*
			GetWalletStatus
		*/
	case gwc.CWalletRequestGetWalletStatus:
		app.infoLog.Println("WalletStatus request detected...")
		var resp models.WalletStatusStruct
		resp.IsInstalled = gwc.IsGoWalletInstalled(gwc.APPTServer)
		app.infoLog.Println("Attempting to GetWalletInfo...")
		wi, _, err := bend.GetWalletInfo(true)
		if err != nil {
			// We did not get a response within the time frame, so return
			app.infoLog.Println("No response from coin daemon, so returning to caller")
			resp.ResponseCode = gwc.WalletDidNotRespondInTime
			bytes, err := json.MarshalIndent(resp, "", "  ")
			if err != nil {
				app.serverError(w, err)
				return
			}
			app.success(w, string(bytes))
			return
		}
		app.infoLog.Println("WalletInfo received")
		if wi.EncryptionStatus == "encrypted" {
			resp.IsWalletEncrypted = true
		} else {
			resp.IsWalletEncrypted = false
		}
		SrvConf, err := gwc.GetServerConfStruct()
		resp.HasPrivKeyBeenSaved = SrvConf.UserConfirmedSeedRecovery
		resp.ResponseCode = gwc.NoServerError

		bytes, err := json.MarshalIndent(resp, "", "  ")
		if err != nil {
			app.serverError(w, err)
			return
		}
		app.infoLog.Println("Returning WalletInfo to caller...")
		app.success(w, string(bytes))
		/*
			SetPrivKeyStored
		*/
	case gwc.CWalletRequestSetPrivSeedStored:
		app.infoLog.Println("SetPrivSeedStored request detected...")
		SrvConf, err := gwc.GetServerConfStruct()
		if err != nil {
			app.serverError(w, err)
			return
		}
		SrvConf.UserConfirmedSeedRecovery = true
		err = gwc.SetServerConfStruct(SrvConf)
		if err != nil {
			app.serverError(w, err)
			return
		}

		var resp models.WalletStatusStruct
		resp.HasPrivKeyBeenSaved = true
		resp.ResponseCode = gwc.NoServerError

		bytes, err := json.MarshalIndent(resp, "", "  ")
		if err != nil {
			app.serverError(w, err)
			return
		}
		app.infoLog.Println("Returning confirmation to caller...")
		app.success(w, string(bytes))
	default:
		var resp struct {
			Desc string `json: "Desc"`
		}

		resp.Desc = "Unknown request: " + wallet.WalletRequest
		bytes, err := json.MarshalIndent(resp, "", "  ")
		if err != nil {
			app.badRequest(w, "Unknown request: "+wallet.WalletRequest)
			return
		}
		app.success(w, string(bytes))
	}

}
