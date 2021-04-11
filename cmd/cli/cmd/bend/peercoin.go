package bend

const (
	CCoinNamePeercoin   string = "Peercoin"
	CCoinAbbrevPeercoin string = "PPC"

	CCoreVersionPeercoin string = "0.9.0"
	CDFFileArm32Peercoin        = "peercoin-" + CCoreVersionPeercoin + "-arm-linux-gnueabihf.tar.gz"
	CDFFileArm64Peercoin        = "peercoin-" + CCoreVersionPeercoin + "-aarch64-linux-gnu.tar.gz"
	//CDFFileLinux32Peercoin = "peercoin-" + CCoreVersionPeercoin + "-linux32.tar.gz"
	CDFFileLinux64Peercoin = "peercoin-" + CCoreVersionPeercoin + "-x86_64-linux-gnu.tar.gz"
	CDFFilemacOSPeercoin   = "peercoin-" + CCoreVersionPeercoin + "-osx64.tar.gz"
	//CDFFileWindowsPeercoin = "peercoin-" + CCoreVersionPeercoin + "-win64.zip"

	// Directory constants
	CExtractedDirArmPeercoin     string = "peercoin-" + CCoreVersionPeercoin + "/"
	CExtractedDirLinuxPeercoin   string = "" //"bitcoinplus-" + CCoreVersionPeercoin + "/"
	CExtractedDirWindowsPeercoin string = "" //"bitcoinplus-" + CCoreVersionPeercoin + "\\"

	CDownloadURLPeercoin string = "https://github.com/peercoin/peercoin/releases/download/v" + CCoreVersionPeercoin + "ppc/"

	// Peercoin Wallet Constants
	cHomeDirLinPeercoin string = ".peercoin"
	cHomeDirWinPeercoin string = "peercoin"

	// File constants
	cConfFilePeercoin   string = "peercoin.conf"
	CCliFilePeercoin    string = "peercoin-cli"
	CCliFileWinPeercoin string = "peercoin-cli.exe"
	CDFilePeercoin      string = "peercoind"
	CDFileWinPeercoin   string = "peercoind.exe"
	CTxFilePeercoin     string = "peercoin-tx"
	CTxFileWinPeercoin  string = "peercoin-tx.exe"

	// pivx.conf file constants.
	CRPCUserPeercoin string = "peercoinrpc"
	CRPCPortPeercoin string = "9902"
)
