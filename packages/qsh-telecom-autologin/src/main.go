package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"html"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	log "github.com/sirupsen/logrus"
)

// So what's this and why is it there?
var confusingString = ">111111111"

const (
	defaultInitialURL  = "http://connectivitycheck.gstatic.com/generate_204"
	maxPortalRedirects = 12
)

var captiveProbeURLs = []string{
	defaultInitialURL,
	"http://123.123.123.123/",
	"http://neverssl.com/",
}

var baseHeader = map[string]string{
	"Accept":          "*/*",
	"Accept-Encoding": "gzip, deflate",
	"Accept-Language": "en,zh-CN;q=0.7",
	"Connection":      "keep-alive",
	"Content-Type":    "application/x-www-form-urlencoded; charset=UTF-8",
	"User-Agent":      "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/118.0",
}

type loginClient struct {
	c           http.Client
	localIP     string
	cachePath   string
	username    string
	password    string
	exponent    string
	modulus     string
	passwordEnc string
	initHost    string
	loginHost   string
	queryString string
	userIndex   string
	portalMain  *url.URL
	nodeMac     string
}

func (c *loginClient) Get(urlString string) *http.Response {
	req, err := http.NewRequest("GET", urlString, nil)
	if err != nil {
		log.Panic("Cannot make request: ", err)
	}

	return c.Do(req)
}

func (c *loginClient) tryGet(urlString string) (*http.Response, error) {
	req, err := http.NewRequest("GET", urlString, nil)
	if err != nil {
		return nil, fmt.Errorf("cannot make request: %w", err)
	}

	return c.tryDo(req)
}

func (c *loginClient) Post(urlString string, body io.Reader) *http.Response {
	req, err := http.NewRequest("POST", urlString, body)
	if err != nil {
		log.Panic("Cannot make request: ", err)
	}

	return c.Do(req)
}

// find interface by IP
func findInterfaceByIP(ip net.IP) *net.Interface {
	// log.Infof("request ip: %s", ip)
	ifaces, err := net.Interfaces()
	if err != nil {
		log.Panic("get interface list failed: ", err)
	}
	for _, iface := range ifaces {
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ipNet *net.IPNet
			var addrIP net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ipNet = v
				addrIP = v.IP
			case *net.IPAddr:
				ipNet = &net.IPNet{IP: v.IP, Mask: v.IP.DefaultMask()}
				addrIP = v.IP
			}
			if ipNet != nil && addrIP.Equal(ip) {
				// log.Infof("ip bound to iface %s",iface)
				return &iface
			}
		}
	}

	log.Panicf("IP %s doesnt belong to any interface", ip.String())
	return nil
}

// dialerWithInterface returns a net.Dialer，which binds socket to specified interface when establishing connection
// linux only
func dialerWithInterface(iface string) *net.Dialer {
	return &net.Dialer{
		Timeout:   30 * time.Second,
		KeepAlive: 30 * time.Second,
		Control: func(network, address string, c syscall.RawConn) error {
			return bindToDevice(c, iface)
		},
	}
}

func (c *loginClient) tryDo(req *http.Request) (*http.Response, error) {
	var dialContext func(ctx context.Context, network, addr string) (net.Conn, error)

	if c.localIP != "" {
		localIP := net.ParseIP(c.localIP)
		if localIP == nil {
			log.Fatalf("Invalid local IP: %s", c.localIP)
		}

		iface := findInterfaceByIP(localIP)

		dialer := dialerWithInterface(iface.Name)
		dialContext = dialer.DialContext

	} else {
		dialer := &net.Dialer{
			Timeout:   30 * time.Second,
			KeepAlive: 30 * time.Second,
		}
		dialContext = dialer.DialContext
	}

	c.c.Transport = &http.Transport{
		DialContext: dialContext,
	}

	for k, v := range baseHeader {
		req.Header.Add(k, v)
	}
	// disable 302 redirect in http module itself
	c.c.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}
	c.c.Timeout = 20 * time.Second

	resp, err := c.c.Do(req)
	if err != nil {
		return nil, err
	}

	return resp, nil
}

func (c *loginClient) Do(req *http.Request) *http.Response {
	resp, err := c.tryDo(req)
	if err != nil {
		log.Panic("Cannot connect: ", err)
	}

	return resp
}

func (c *loginClient) PasswordEncrypt() {
	if (c.modulus != "") && (c.exponent != "") && (c.password != "") {
		c.password = c.password + confusingString
		// just very simple RSA with no padding
		m, _ := new(big.Int).SetString(c.modulus, 16)
		e, _ := new(big.Int).SetString(c.exponent, 16)
		p := new(big.Int).SetBytes([]byte(c.password))
		crypted := new(big.Int).Exp(p, e, m)
		c.passwordEnc = hex.EncodeToString(crypted.Bytes())
	} else if c.passwordEnc != "" {
		return
	} else if c.password == "" {
		log.Panic("Cannot encrypt password: password not given")
	} else {
		log.Panic("Cannot encrypt password: not enough arguments")
	}
}

func (c *loginClient) myPost(urlString string, reqData map[string]string, respData interface{}) {
	formData := url.Values{}
	for key, value := range reqData {
		formData.Add(key, value)
	}
	body := strings.NewReader(formData.Encode())
	resp := c.Post(urlString, body)
	err := json.NewDecoder(resp.Body).Decode(respData)
	if err != nil {
		log.Panic("Failed to decode response: ", err)
	}
	defer resp.Body.Close()
}

func normalizeInitialURL(host string) string {
	host = strings.TrimSpace(host)
	if strings.HasPrefix(host, "http://") || strings.HasPrefix(host, "https://") {
		return host
	}
	return "http://" + strings.TrimLeft(host, "/")
}

func isRedirectStatus(status int) bool {
	switch status {
	case http.StatusMovedPermanently, http.StatusFound, http.StatusSeeOther,
		http.StatusTemporaryRedirect, http.StatusPermanentRedirect:
		return true
	default:
		return false
	}
}

func resolveRedirectURL(currentURL, location string) (string, error) {
	base, err := url.Parse(currentURL)
	if err != nil {
		return "", err
	}
	next, err := url.Parse(location)
	if err != nil {
		return "", err
	}
	return base.ResolveReference(next).String(), nil
}

func isUsefulPortalInitURL(urlString string) bool {
	u, err := url.Parse(urlString)
	if err != nil {
		return false
	}
	return strings.Contains(u.Path, "/portal/portal-main") ||
		strings.Contains(u.Path, "/eportal/") ||
		u.Query().Get("userip") != "" ||
		u.Query().Get("nasip") != ""
}

func appendUniqueURL(urls []string, urlString string) []string {
	normalized := strings.TrimRight(urlString, "/")
	for _, existing := range urls {
		if strings.EqualFold(strings.TrimRight(existing, "/"), normalized) {
			return urls
		}
	}
	return append(urls, urlString)
}

func (c *loginClient) resetPortalInitState() {
	c.loginHost = ""
	c.queryString = ""
	c.portalMain = nil
	c.nodeMac = ""
}

func (c *loginClient) followPortalRedirects(startURL string) (string, int, error) {
	urlString := startURL
	seen := map[string]bool{}

	for redirectCount := 0; redirectCount < maxPortalRedirects; redirectCount++ {
		if seen[urlString] {
			return "", 0, fmt.Errorf("redirect loop at %s", urlString)
		}
		seen[urlString] = true

		resp, err := c.tryGet(urlString)
		if err != nil {
			return "", 0, err
		}

		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()

		if isRedirectStatus(resp.StatusCode) {
			location := resp.Header.Get("Location")
			if location == "" {
				return "", resp.StatusCode, fmt.Errorf("redirect response does not include Location")
			}
			nextURL, err := resolveRedirectURL(urlString, location)
			if err != nil {
				return "", resp.StatusCode, fmt.Errorf("redirect response includes illegal Location %q: %w", location, err)
			}
			c.rememberRedirectParams(nextURL)
			urlString = nextURL
			continue
		}

		u, err := url.Parse(urlString)
		if err != nil {
			return "", resp.StatusCode, fmt.Errorf("returned illegal url %q: %w", urlString, err)
		}
		c.loginHost = u.Host
		c.queryString = u.RawQuery
		if strings.Contains(u.Path, "/portal/portal-main") {
			c.portalMain = u
		}
		return urlString, resp.StatusCode, nil
	}

	return "", 0, fmt.Errorf("too many redirects")
}

func (c *loginClient) loginInit() {
	candidates := []string{normalizeInitialURL(c.initHost)}
	for _, probeURL := range captiveProbeURLs {
		candidates = appendUniqueURL(candidates, probeURL)
	}

	var attempts []string
	for i, candidate := range candidates {
		c.resetPortalInitState()
		finalURL, status, err := c.followPortalRedirects(candidate)
		if err != nil {
			attempts = append(attempts, fmt.Sprintf("%s: %v", candidate, err))
			if i == 0 {
				log.Warnf("Initial portal entry %s failed: %v; trying captive HTTP probes", candidate, err)
			}
			continue
		}

		if c.portalMain != nil || isUsefulPortalInitURL(finalURL) {
			if i > 0 {
				log.Warnf("Using captive HTTP probe %s after initial portal entry was unavailable", candidate)
			}
			return
		}

		attempts = append(attempts, fmt.Sprintf("%s: ended at %s with HTTP %d and no portal redirect", candidate, finalURL, status))
		if i == 0 {
			log.Warnf("Initial portal entry %s did not return a portal redirect; trying captive HTTP probes", candidate)
		}
	}

	log.Panicf("Cannot initialize login portal. Attempts: %s", strings.Join(attempts, "; "))
}

func (c *loginClient) rememberRedirectParams(urlString string) {
	u, err := url.Parse(urlString)
	if err != nil {
		return
	}
	if c.nodeMac == "" {
		c.nodeMac = u.Query().Get("wlanparameter")
	}
	if strings.Contains(u.Path, "/portal/portal-main") {
		c.portalMain = u
	}
}

func absoluteURL(baseHost, maybeRelative string) string {
	u, err := url.Parse(maybeRelative)
	if err == nil && u.IsAbs() {
		return maybeRelative
	}
	if strings.HasPrefix(maybeRelative, "/") {
		return "http://" + baseHost + maybeRelative
	}
	return "http://" + baseHost + "/" + maybeRelative
}

func extractHiddenParagraph(body, id string) string {
	pattern := `<p\s+id=["']` + regexp.QuoteMeta(id) + `["']\s*>(.*?)</p>`
	re := regexp.MustCompile("(?is)" + pattern)
	match := re.FindStringSubmatch(body)
	if len(match) < 2 {
		return ""
	}
	return strings.TrimSpace(html.UnescapeString(match[1]))
}

func pkcs7Pad(data []byte, blockSize int) []byte {
	padding := blockSize - len(data)%blockSize
	return append(data, bytes.Repeat([]byte{byte(padding)}, padding)...)
}

func aesECBEncryptBase64(keyBase64, plaintext string) string {
	key, err := base64.StdEncoding.DecodeString(keyBase64)
	if err != nil {
		log.Panic("Cannot decode CAS crypto key: ", err)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		log.Panic("Cannot initialize CAS AES cipher: ", err)
	}
	src := pkcs7Pad([]byte(plaintext), block.BlockSize())
	dst := make([]byte, len(src))
	for bs := 0; bs < len(src); bs += block.BlockSize() {
		block.Encrypt(dst[bs:bs+block.BlockSize()], src[bs:bs+block.BlockSize()])
	}
	return base64.StdEncoding.EncodeToString(dst)
}

func (c *loginClient) ensureCookieJar() {
	if c.c.Jar != nil {
		return
	}
	jar, err := cookiejar.New(nil)
	if err != nil {
		log.Panic("Cannot create cookie jar: ", err)
	}
	c.c.Jar = jar
}

func (c *loginClient) buildCASLoginURL() string {
	if c.portalMain == nil {
		log.Panic("Cannot build CAS login URL without portal-main redirect")
	}
	portalQuery := c.portalMain.Query()
	casQuery := url.Values{}
	casQuery.Set("flowSessionId", portalQuery.Get("sessionId"))
	casQuery.Set("customPageId", portalQuery.Get("customPageId"))
	casQuery.Set("preview", "false")
	casQuery.Set("appType", "normal")
	casQuery.Set("language", "zh-CN")
	casQuery.Set("userIp", portalQuery.Get("userIp"))
	casQuery.Set("nasIp", portalQuery.Get("nasIp"))
	if c.nodeMac != "" {
		casQuery.Set("nodeMac", c.nodeMac)
	}
	casQuery.Set("timer", strconv.FormatInt(time.Now().UnixMilli(), 10))
	return "http://" + c.loginHost + "/cas-sso/login?" + casQuery.Encode()
}

func (c *loginClient) casLogin() {
	c.ensureCookieJar()

	casURL := c.buildCASLoginURL()
	resp := c.Get(casURL)
	bodyBytes, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		log.Panic("Cannot read CAS login page: ", err)
	}
	if resp.StatusCode != http.StatusOK {
		log.Panicf("CAS login page returned unexpected status %d", resp.StatusCode)
	}
	body := string(bodyBytes)
	cryptoKey := extractHiddenParagraph(body, "login-croypto")
	execution := extractHiddenParagraph(body, "login-page-flowkey")
	loginType := extractHiddenParagraph(body, "current-login-type")
	if loginType == "" {
		loginType = "UsernamePassword"
	}
	if cryptoKey == "" || execution == "" {
		log.Panic("Cannot parse CAS login page: missing crypto key or execution token")
	}

	actionURL, err := url.Parse(casURL)
	if err != nil {
		log.Panic("Cannot parse CAS action URL: ", err)
	}
	actionQuery := actionURL.Query()
	actionQuery.Set("accept-language", "zh-CN")
	actionURL.RawQuery = actionQuery.Encode()

	formData := url.Values{}
	formData.Set("username", c.username)
	formData.Set("type", loginType)
	formData.Set("_eventId", "submit")
	formData.Set("geolocation", "")
	formData.Set("execution", execution)
	formData.Set("captcha_code", "")
	formData.Set("croypto", cryptoKey)
	formData.Set("password", aesECBEncryptBase64(cryptoKey, c.password))
	formData.Set("captcha_payload", aesECBEncryptBase64(cryptoKey, "{}"))

	req, err := http.NewRequest("POST", actionURL.String(), strings.NewReader(formData.Encode()))
	if err != nil {
		log.Panic("Cannot make CAS login request: ", err)
	}
	req.Header.Set("Referer", casURL)
	req.Header.Set("Origin", "http://"+c.loginHost)
	resp = c.Do(req)
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusFound {
		location := resp.Header.Get("Location")
		if strings.Contains(location, "/portal/assets/auth-success.html") {
			successURL := absoluteURL(c.loginHost, location)
			successResp := c.Get(successURL)
			io.Copy(io.Discard, successResp.Body)
			successResp.Body.Close()
			log.Infof("Successfully logged in with account '%s' using CAS portal", c.username)
			return
		}
		log.Panicf("CAS login redirected to unexpected location: %s", location)
	}

	respBody, _ := io.ReadAll(resp.Body)
	errorMsg := extractHiddenParagraph(string(respBody), "loginFailMessage")
	errorCode := extractHiddenParagraph(string(respBody), "login-error-code")
	if errorMsg == "" {
		errorMsg = strings.TrimSpace(errorCode)
	}
	if errorMsg != "" {
		log.Panicf("CAS login attempt failed with account '%s': %s", c.username, errorMsg)
	}
	log.Panicf("CAS login attempt failed with account '%s', status %d", c.username, resp.StatusCode)
}

func (c *loginClient) getEncryptKey() {
	urlString := "http://" + c.loginHost + "/eportal/InterFace.do?method=pageInfo"
	reqData := map[string]string{
		"queryString": c.queryString,
	}
	type respStruct struct {
		PublicKeyExponent string
		PublicKeyModulus  string
	}
	respData := respStruct{}
	c.myPost(urlString, reqData, &respData)
	c.exponent = respData.PublicKeyExponent
	if c.modulus != respData.PublicKeyModulus {
		if c.modulus != "" {
			log.Info("Encryption modulus is changed")
		}
		c.modulus = respData.PublicKeyModulus
	}
	c.PasswordEncrypt()
}

func (c *loginClient) login() {
	urlString := "http://" + c.loginHost + "/eportal/InterFace.do?method=login"
	reqData := map[string]string{
		"userId":          c.username,
		"password":        c.passwordEnc,
		"service":         "",
		"queryString":     c.queryString,
		"operatorPwd":     "",
		"operatorUserId":  "",
		"validcode":       "",
		"passwordEncrypt": "true",
	}
	type respStruct struct {
		Result    string
		UserIndex string
	}
	respData := respStruct{}
	c.myPost(urlString, reqData, &respData)
	if respData.Result == "success" {
		c.userIndex = respData.UserIndex
		log.Infof("Successfully logged in with account '%s'", c.username)
	} else {
		log.Panicf("Login attempt failed with account '%s'", c.username)
	}
}

func (c *loginClient) logout() {
	urlString := "http://" + c.initHost + "/eportal/InterFace.do?method=logout"
	reqData := map[string]string{
		"userIndex": c.userIndex,
	}
	type respStruct struct {
		Result string
	}
	respData := respStruct{}
	c.myPost(urlString, reqData, &respData)
	if respData.Result == "success" {
		log.Info("Successfully logged out")
	} else {
		log.Panic("Logout attempt failed, maybe user index has expired")
	}
}

type cache struct {
	Username    string
	PasswordEnc string
	InitHost    string
	UserIndex   string
	Modulus     string
}

func (c *loginClient) loadCache() {
	if c.cachePath == "" {
		return
	}
	path, _ := filepath.Abs(c.cachePath)
	file, err := os.ReadFile(path)
	if err != nil {
		return
	}
	fileCache := cache{}
	err = json.Unmarshal([]byte(file), &fileCache)
	if err != nil {
		log.Panic("Cannot parse cache file: ", err)
	}
	if c.username == "" {
		c.username = fileCache.Username
	}
	if c.initHost == "" {
		c.initHost = fileCache.InitHost
	}
	c.passwordEnc = fileCache.PasswordEnc
	if c.userIndex == "" {
		c.userIndex = fileCache.UserIndex
	}
	c.modulus = fileCache.Modulus
}

func (c *loginClient) saveCache() {
	if c.cachePath == "" {
		return
	}
	fileCache := cache{
		Username:    c.username,
		PasswordEnc: c.passwordEnc,
		InitHost:    c.initHost,
		UserIndex:   c.userIndex,
		Modulus:     c.modulus,
	}
	file, _ := json.MarshalIndent(fileCache, "", " ")
	path, _ := filepath.Abs(c.cachePath)
	err := os.WriteFile(path, file, 0666)
	if err != nil {
		log.Panic("Failed to write to cache file: ", err)
	}
}

func (c *loginClient) run() {
	flag.StringVar(&c.username, "name", "", "Account name, usually phone number")
	flag.StringVar(&c.password, "passwd", "", "Password to the account")
	flag.StringVar(&c.initHost, "host", defaultInitialURL, "Initial login URL or host; HTTP captive portal probe is recommended")
	flag.StringVar(&c.cachePath, "cache", "", "Specify where to read and store cache, blank to disable")
	flag.StringVar(&c.userIndex, "index", "", "User Index of user, only for logging out")
	flag.StringVar(&c.localIP, "localip", "", "Local IP address to bind to")
	logout := flag.Bool("logout", false, "Whether to log out current user")
	flag.Parse()

	if !*logout {
		if (c.cachePath == "") && (c.username == "" || c.password == "") {
			log.Panic("Not enough argument for login. See --help for explanation")
		}
		c.loadCache()
		c.loginInit()
		if c.portalMain != nil {
			c.casLogin()
		} else {
			c.getEncryptKey()
			c.login()
		}
		c.saveCache()
	} else {
		if (c.cachePath == "") && (c.userIndex == "") {
			log.Panic("Not enough argument for logout. See --help for explanation")
		}
		c.loadCache()
		c.logout()
	}
}

func init() {
	// Set logrus format
	log.SetFormatter(&log.TextFormatter{
		FullTimestamp: true,
	})
	// Set log level
	log.SetLevel(log.InfoLevel)
}

func main() {
	defer os.Exit(1)
	client := &loginClient{}
	client.run()
	os.Exit(0)
}
