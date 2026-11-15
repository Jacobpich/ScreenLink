package main

import (
	"bufio"
	"bytes"
	"crypto/aes"
	"crypto/md5"
	"crypto/rand"
	"errors"
	"io"
	"math/big"
	"net"
)

// RFC 3526 group 14 (2048-bit MODP), generator 2.
var dhPrime, _ = new(big.Int).SetString(
	"FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD"+
		"EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"+
		"EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"+
		"83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"+
		"E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510"+
		"15728E5A8AACAA68FFFFFFFFFFFFFFFF", 16)

// serverAppleAuth runs the server side of security type 30 (the same exchange macOS uses):
// Diffie-Hellman agrees a key, and the viewer sends its username and password AES-encrypted
// with MD5(shared secret). The password never crosses the network in the clear, and on top of
// that the connection itself runs inside Tailscale's encrypted tunnel.
func serverAppleAuth(c net.Conn, r *bufio.Reader) (user, pass string, err error) {
	keyLen := (dhPrime.BitLen() + 7) / 8
	priv, err := rand.Int(rand.Reader, new(big.Int).Sub(dhPrime, big.NewInt(3)))
	if err != nil {
		return "", "", err
	}
	priv.Add(priv, big.NewInt(2))
	pub := new(big.Int).Exp(big.NewInt(2), priv, dhPrime)

	msg := []byte{0, 2, byte(keyLen >> 8), byte(keyLen)}
	msg = append(msg, dhPrime.FillBytes(make([]byte, keyLen))...)
	msg = append(msg, pub.FillBytes(make([]byte, keyLen))...)
	if _, err := c.Write(msg); err != nil {
		return "", "", err
	}

	resp := make([]byte, 128+keyLen)
	if _, err := io.ReadFull(r, resp); err != nil {
		return "", "", err
	}
	clientPub := new(big.Int).SetBytes(resp[128:])
	pMinus1 := new(big.Int).Sub(dhPrime, big.NewInt(1))
	if clientPub.Cmp(big.NewInt(1)) <= 0 || clientPub.Cmp(pMinus1) >= 0 {
		return "", "", errors.New("viewer sent an invalid key")
	}
	shared := new(big.Int).Exp(clientPub, priv, dhPrime).FillBytes(make([]byte, keyLen))
	key := md5.Sum(shared)
	block, _ := aes.NewCipher(key[:])
	creds := make([]byte, 128)
	for i := 0; i < 128; i += 16 { // ECB
		block.Decrypt(creds[i:i+16], resp[i:i+16])
	}
	return cstr(creds[:64]), cstr(creds[64:]), nil
}

func cstr(b []byte) string {
	if i := bytes.IndexByte(b, 0); i >= 0 {
		b = b[:i]
	}
	return string(b)
}
