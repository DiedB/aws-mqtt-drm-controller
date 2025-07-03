package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/iotdataplane"
)

const (
	PURCHASE_FEE_FEED_IN  = -0.012705
	FRANK_ENERGIE_API_URL = "https://www.frankenergie.nl/graphql"
)

// GraphQL request structure
type GraphQLRequest struct {
	Query         string                 `json:"query"`
	Variables     map[string]interface{} `json:"variables"`
	OperationName string                 `json:"operationName"`
}

// Response structures
type MarketPricesResponse struct {
	Data struct {
		MarketPrices struct {
			ElectricityPrices []ElectricityPrice `json:"electricityPrices"`
		} `json:"marketPrices"`
	} `json:"data"`
}

type ElectricityPrice struct {
	From        string  `json:"from"`
	Till        string  `json:"till"`
	MarketPrice float64 `json:"marketPrice"`
	PerUnit     string  `json:"perUnit"`
}

// IoT command structure
type IoTCommand struct {
	Command   string `json:"command"`
	Timestamp string `json:"timestamp"`
	Reason    string `json:"reason"`
}

func handler(ctx context.Context) error {
	// Get current date in the required format
	now := time.Now()
	date := now.Format("2006-01-02")

	// Fetch market prices
	prices, err := fetchMarketPrices(date)
	if err != nil {
		log.Printf("Error fetching market prices: %v", err)
		return err
	}

	// Find current hour's price
	currentPrice, err := getCurrentHourPrice(prices, now)
	if err != nil {
		log.Printf("Error finding current hour price: %v", err)
		return err
	}

	log.Printf("Current market price: €%.5f/kWh", currentPrice)

	// Apply the decision logic
	effectivePrice := currentPrice + PURCHASE_FEE_FEED_IN

	shouldDisableSolar := effectivePrice < 0

	log.Printf("Effective price (market + feed-in fee): €%.5f/kWh", effectivePrice)
	log.Printf("Should disable solar inverter: %t", shouldDisableSolar)

	// Send command to IoT Core via HTTPS
	err = sendIoTCommand(ctx, shouldDisableSolar)
	if err != nil {
		log.Printf("Error sending IoT command: %v", err)
		return err
	}

	log.Printf("Solar panel control completed successfully")
	return nil
}

func fetchMarketPrices(date string) ([]ElectricityPrice, error) {
	// Prepare GraphQL query
	query := `query MarketPrices($date: String!) {
		marketPrices(date: $date) {
			electricityPrices {
				from
				till
				marketPrice
				perUnit
			}
		}
	}`

	reqBody := GraphQLRequest{
		Query: query,
		Variables: map[string]interface{}{
			"date": date,
		},
		OperationName: "MarketPrices",
	}

	jsonData, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("error marshaling request: %w", err)
	}

	// Make HTTP request
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest("POST", FRANK_ENERGIE_API_URL, bytes.NewBuffer(jsonData))
	if err != nil {
		return nil, fmt.Errorf("error creating request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("error making request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("API returned status code: %d", resp.StatusCode)
	}

	var response MarketPricesResponse
	err = json.NewDecoder(resp.Body).Decode(&response)
	if err != nil {
		return nil, fmt.Errorf("error decoding response: %w", err)
	}

	return response.Data.MarketPrices.ElectricityPrices, nil
}

func getCurrentHourPrice(prices []ElectricityPrice, currentTime time.Time) (float64, error) {
	// Convert current time to UTC for comparison
	currentUTC := currentTime.UTC()

	for _, price := range prices {
		fromTime, err := time.Parse(time.RFC3339, price.From)
		if err != nil {
			continue
		}

		tillTime, err := time.Parse(time.RFC3339, price.Till)
		if err != nil {
			continue
		}

		// Check if current time falls within this price period
		if currentUTC.After(fromTime) && currentUTC.Before(tillTime) || currentUTC.Equal(fromTime) {
			log.Printf("Found matching price period: %s - %s", price.From, price.Till)
			return price.MarketPrice, nil
		}
	}

	return 0, fmt.Errorf("no price found for current hour: %s", currentUTC.Format(time.RFC3339))
}

func sendIoTCommand(ctx context.Context, shouldDisable bool) error {
	// Get IoT Core endpoint and Shelly client ID from environment variables
	iotEndpoint := os.Getenv("IOT_ENDPOINT")
	shellyClientId := os.Getenv("SHELLY_CLIENT_ID")

	if iotEndpoint == "" || shellyClientId == "" {
		return fmt.Errorf("IOT_ENDPOINT and SHELLY_CLIENT_ID environment variables must be set")
	}

	// Load AWS configuration
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return fmt.Errorf("error loading AWS config: %w", err)
	}

	// Construct the full HTTPS endpoint URL for IoT Data Plane
	fullEndpoint := fmt.Sprintf("https://%s", iotEndpoint)

	// Create IoT Data client with custom endpoint
	iotClient := iotdataplane.NewFromConfig(cfg, func(o *iotdataplane.Options) {
		o.BaseEndpoint = &fullEndpoint
	})

	// Prepare IoT command
	command := "off"

	if shouldDisable {
		command = "on"
	}

	// Publish to IoT Core
	topic := fmt.Sprintf("%s/command/switch:0", shellyClientId)
	input := &iotdataplane.PublishInput{
		Topic:   &topic,
		Payload: []byte(command),
	}

	_, err = iotClient.Publish(ctx, input)
	if err != nil {
		return fmt.Errorf("error publishing to IoT Core: %w", err)
	}

	log.Printf("Successfully published IoT command: %s to topic: %s", command, topic)

	return nil
}

func main() {
	lambda.Start(handler)
}
