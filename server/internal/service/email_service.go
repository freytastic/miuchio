package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"
)

type EmailService interface {
	SendOTP(email, otp string) error
}

// ConsoleEmailService prints codes to stdout and is only wired in dev mode
// without a Resend key: a production server must never log a sign-in code
type ConsoleEmailService struct{}

func (ConsoleEmailService) SendOTP(email, otp string) error {
	fmt.Printf("dev sign-in code: %s -> %s\n", email, otp)
	return nil
}

func (ConsoleEmailService) SendDeletionCode(_ context.Context, email, code string) error {
	fmt.Printf("dev deletion code: %s -> %s\n", email, code)
	return nil
}

type ResendEmailService struct {
	APIKey string
	From   string
	client *http.Client
}

// Bounded so a stalled provider cannot hold a sender forever
const emailSendTimeout = 10 * time.Second

func NewResendEmailService(apiKey, from string) *ResendEmailService {
	return &ResendEmailService{APIKey: apiKey, From: from, client: &http.Client{Timeout: emailSendTimeout}}
}

func (s *ResendEmailService) SendOTP(email, otp string) error {
	return s.send(context.Background(), email, "Your Miuchio Login Code",
		fmt.Sprintf("<strong>Your Miuchio login code is: %s</strong>. This code will expire in 5 minutes.", otp))
}

// Worded apart from the sign-in email so nobody can pass it off as a login code
func (s *ResendEmailService) SendDeletionCode(ctx context.Context, email, code string) error {
	return s.send(ctx, email, "Code to delete your Miuchio account", fmt.Sprintf(
		"<p>Someone asked to delete the Miuchio account for this address on miuchio.com.</p>"+
			"<p>If it was you, your code is <strong>%s</strong>. It expires in 5 minutes.</p>"+
			"<p>If it was not you, ignore this email. Nothing happens without the code. "+
			"Never share it with anyone, including someone who says they are from Miuchio.</p>", code))
}

func (s *ResendEmailService) send(ctx context.Context, email, subject, html string) error {
	url := "https://api.resend.com/emails"
	payload := map[string]interface{}{
		"from":    s.From,
		"to":      email,
		"subject": subject,
		"html":    html,
	}

	jsonPayload, _ := json.Marshal(payload)
	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewBuffer(jsonPayload))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+s.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		// only the error name is logged: Resend messages can echo addresses
		var apiErr struct {
			Name string `json:"name"`
		}
		_ = json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&apiErr)
		log.Printf("Resend API failed: status %d, error %q", resp.StatusCode, apiErr.Name)
		return fmt.Errorf("failed to send email: status code %d", resp.StatusCode)
	}

	return nil
}
