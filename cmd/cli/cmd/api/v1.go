package api

import (
	"encoding/json"
	"fmt"
	"github.com/gin-gonic/gin"
	"io"
	"log"
	"net/http"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/divi"
	rdd "richardmace.co.uk/boxwallet/cmd/cli/cmd/coins/reddcoin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
)

type apiResponse struct {
	CoreFilesExist bool `json:"core_files_exist"`
}

type apiRequest struct {
	BoxWalletDir string `json:"boxwallet_dir"`
	CoinType     int    `json:"coin_type"`
	MethodType   int    `json:"method_type"`
}

type RESTApiV1 struct {
	router *gin.Engine
}

func (api *RESTApiV1) Init() {
	api.router = gin.Default()

	api.router.POST(path("coin"), api.processCoinRequest)
	//api.router.GET(path("coins"), api.GetCoins)
	//api.router.GET(path("swaps"), api.GetSwaps)
	//api.router.PUT(path("swaps"), api.AddSwap)
	//
	//_ = api.initAPIKeys()
}

func path(endpoint string) string {
	print("Listening on: " + endpoint)
	return fmt.Sprintf("/api/v1/%s", endpoint)
}

func (api *RESTApiV1) Serve(addr string) error {
	return api.router.Run(addr)
}

func (api *RESTApiV1) processCoinRequest(c *gin.Context) {
	//print("Hitting processCoinRequest...")
	jsonData, err := io.ReadAll(c.Request.Body)
	if err != nil {
		print("error: " + err.Error())
	}
	var apiRequest apiRequest
	err = json.Unmarshal(jsonData, &apiRequest)
	if err != nil {
		print("error: " + err.Error())
	}

	fmt.Println("apiRequest", apiRequest)

	var coin coins.Coin

	switch models.ProjectType(apiRequest.CoinType) {
	case models.PTReddCoin:
		coin = rdd.ReddCoin{}
	case models.PTDivi:
		coin = divi.Divi{}
	default:
		log.Fatal("Unable to determine coin choice")
	}

	switch models.CoinMethodType(apiRequest.MethodType) {
	case models.CMTcore_files_exist:
		var resp apiResponse
		resp.CoreFilesExist, _ = coin.AllBinaryFilesExist(apiRequest.BoxWalletDir)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{
				"core_files_exist": resp.CoreFilesExist,
			})
		}
		//jm, _ := json.Marshal(resp)
		c.IndentedJSON(http.StatusOK, resp)

	default:
		log.Fatal("Unable to determine coin choice")
	}

	//coins, err := api.coinsService.GetAllCoins()
	//if err != nil {
	//	c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to fetch projects"})
	//	return
	//}
	//
	//c.JSON(http.StatusOK, gin.H{
	//	"data": coins,
	//})
}

// ... milestones and tasks ...
