package bend

const (
	CCoinNameBitcoinPlus   string = "BitcoinPlus"
	CCoinAbbrevBitcoinPlus string = "XBC"

	CCoreVersionBitcoinPlus string = "2.8.2"
	//CDFBitcoinPlusFileArm32          = "bitcoinplus-" + CCoreVersionBitcoinPlus + "-arm-linux-gnueabihf.tar.gz"
	//CDFBitcoinPlusFileArm64          = "bitcoinplus-" + CCoreVersionBitcoinPlus + "-aarch64-linux-gnu.tar.gz"
	CDFFileLinux32BitcoinPlus = "bitcoinplus-" + CCoreVersionBitcoinPlus + "-linux32.tar.gz"
	CDFFileLinux64BitcoinPlus = "bitcoinplus-" + CCoreVersionBitcoinPlus + "-linux64.tar.gz"
	//CDFFilemacOSBitcoinPlus          = "bitcoinplus-" + CCoreVersionBitcoinPlus + "-osx64.tar.gz"
	//CDFFileWindowsBitcoinPlus        = "bitcoinplus-" + CCoreVersionBitcoinPlus + "-win64.zip"

	// Directory const
	CExtractedDirArmBitcoinPlus     string = "bitcoinplus-" + CCoreVersionBitcoinPlus + "/"
	CExtractedDirLinuxBitcoinPlus   string = "" //"bitcoinplus-" + CCoreVersionBitcoinPlus + "/"
	CExtractedDirWindowsBitcoinPlus string = "" //"bitcoinplus-" + CCoreVersionBitcoinPlus + "\\"

	CDownloadURLBitcoinPlus string = "https://github.com/bitcoinplusorg/xbcwalletsource/releases/download/v" + CCoreVersionBitcoinPlus + "/"

	// BitcoinPlus Wallet Constants
	cHomeDirLinBitcoinPlus string = ".bitcoinplus"
	cHomeDirWinBitcoinPlus string = "bitcoinplus"

	// File constants
	cConfFileBitcoinPlus   string = "bitcoinplus.conf"
	CCliFileBitcoinPlus    string = "bitcoinplus-cli"
	CCliFileWinBitcoinPlus string = "bitcoinplus-cli.exe"
	CDFileBitcoinPlus      string = "bitcoinplusd"
	CDFileWinBitcoinPlus   string = "bitcoinplusd.exe"
	CTxFileBitcoinPlus     string = "bitcoinplus-tx"
	CTxFileWinBitcoinPlus  string = "bitcoinplus-tx.exe"

	// pivx.conf file constants
	CRPCUserBitcoinPlus string = "bitcoinplusrpc"
	CRPCPortBitcoinPlus string = "8885"
)
