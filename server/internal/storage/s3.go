package storage

import (
	"context"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	v4 "github.com/aws/aws-sdk-go-v2/aws/signer/v4"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

type S3Client struct {
	client        *s3.Client
	presignClient *s3.PresignClient
	bucket        string
}

func NewS3Client(endpoint, presignEndpoint, accessKey, secretKey, bucket, region string, usePathStyle bool) (*S3Client, error) {
	// Base client for internal operations (CreateBucket, HeadObject)
	cfg, err := config.LoadDefaultConfig(context.TODO(),
		config.WithRegion(region),
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(accessKey, secretKey, "")),
		config.WithEndpointResolverWithOptions(aws.EndpointResolverWithOptionsFunc(func(service, reg string, options ...interface{}) (aws.Endpoint, error) {
			return aws.Endpoint{
				URL:               endpoint,
				SigningRegion:     region,
				HostnameImmutable: usePathStyle,
			}, nil
		})),
	)
	if err != nil {
		return nil, err
	}

	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.UsePathStyle = usePathStyle
	})

	// A separate presign endpoint lets URLs carry the address the phone can reach
	presignUrl := endpoint
	if presignEndpoint != "" {
		presignUrl = presignEndpoint
	}

	presignCfg, err := config.LoadDefaultConfig(context.TODO(),
		config.WithRegion(region),
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(accessKey, secretKey, "")),
		config.WithEndpointResolverWithOptions(aws.EndpointResolverWithOptionsFunc(func(service, reg string, options ...interface{}) (aws.Endpoint, error) {
			return aws.Endpoint{
				URL:               presignUrl,
				SigningRegion:     region,
				HostnameImmutable: usePathStyle,
			}, nil
		})),
	)
	if err != nil {
		return nil, err
	}

	return &S3Client{
		client: client,
		presignClient: s3.NewPresignClient(s3.NewFromConfig(presignCfg, func(o *s3.Options) {
			o.UsePathStyle = usePathStyle
		})),
		bucket: bucket,
	}, nil
}

// GetPresignedUploadURL returns a PUT URL valid for expires
func (s *S3Client) GetPresignedUploadURL(ctx context.Context, key string, contentType string, expires time.Duration) (string, error) {
	request, err := s.presignClient.PresignPutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(s.bucket),
		Key:         aws.String(key),
		ContentType: aws.String(contentType),
	}, s3.WithPresignExpires(expires))
	if err != nil {
		return "", err
	}

	return request.URL, nil
}

// PresignedUpload is a URL plus the headers the client must send. S3 enforces
// ContentLength and ChecksumSHA256, so a wrong body fails before ConfirmUpload
type PresignedUpload struct {
	URL            string
	RequiredHeader map[string]string // headers the client MUST set on PUT
}

// signChecksumHeader keeps x-amz-checksum-sha256 a signed header instead of a
// query param so R2 accepts it: upload links only, on GET it would also sign
// x-amz-checksum-mode, which the client never sends
func signChecksumHeader(o *s3.PresignOptions) {
	o.Presigner = v4.NewSigner(func(so *v4.SignerOptions) {
		so.DisableHeaderHoisting = true
	})
}

// GetPresignedUploadURLWithChecksum returns a PUT URL that S3 will reject
// unless the body is exactly contentLength bytes and its SHA256 matches
// sha256B64. contentType is set so MinIO doesnt default to octet stream
func (s *S3Client) GetPresignedUploadURLWithChecksum(ctx context.Context, key, contentType string, contentLength int64, sha256B64 string, expires time.Duration) (*PresignedUpload, error) {
	req, err := s.presignClient.PresignPutObject(ctx, &s3.PutObjectInput{
		Bucket:         aws.String(s.bucket),
		Key:            aws.String(key),
		ContentType:    aws.String(contentType),
		ContentLength:  aws.Int64(contentLength),
		ChecksumSHA256: aws.String(sha256B64),
	}, s3.WithPresignExpires(expires), signChecksumHeader)
	if err != nil {
		return nil, err
	}
	return &PresignedUpload{
		URL: req.URL,
		RequiredHeader: map[string]string{
			"Content-Type":          contentType,
			"x-amz-checksum-sha256": sha256B64,
		},
	}, nil
}

// HeadObject returns the stored size and base64 SHA256 for ConfirmUpload to
// compare with the claimed values. ErrObjectNotFound if nothing was uploaded
func (s *S3Client) HeadObject(ctx context.Context, key string) (size int64, sha256B64 string, err error) {
	out, err := s.client.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket:       aws.String(s.bucket),
		Key:          aws.String(key),
		ChecksumMode: "ENABLED",
	})
	if err != nil {
		return 0, "", err
	}
	if out.ContentLength != nil {
		size = *out.ContentLength
	}
	if out.ChecksumSHA256 != nil {
		sha256B64 = *out.ChecksumSHA256
	}
	return size, sha256B64, nil
}

// GetPresignedDownloadURL returns a GET URL valid for expires
func (s *S3Client) GetPresignedDownloadURL(ctx context.Context, key string, expires time.Duration) (string, error) {
	request, err := s.presignClient.PresignGetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	}, s3.WithPresignExpires(expires))
	if err != nil {
		return "", err
	}

	return request.URL, nil
}

// DeleteObjects removes up to 1000 keys in one request and returns the keys
// storage refused. A missing key counts as deleted
func (s *S3Client) DeleteObjects(ctx context.Context, keys []string) ([]string, error) {
	ids := make([]types.ObjectIdentifier, len(keys))
	for i, key := range keys {
		ids[i] = types.ObjectIdentifier{Key: aws.String(key)}
	}
	out, err := s.client.DeleteObjects(ctx, &s3.DeleteObjectsInput{
		Bucket: aws.String(s.bucket),
		Delete: &types.Delete{Objects: ids, Quiet: aws.Bool(true)},
	})
	if err != nil {
		return nil, err
	}
	failed := make([]string, 0, len(out.Errors))
	for _, e := range out.Errors {
		failed = append(failed, aws.ToString(e.Key))
	}
	return failed, nil
}

func (s *S3Client) CreateBucketIfNotExists(ctx context.Context) error {
	_, err := s.client.HeadBucket(ctx, &s3.HeadBucketInput{
		Bucket: aws.String(s.bucket),
	})
	if err != nil {
		_, err = s.client.CreateBucket(ctx, &s3.CreateBucketInput{
			Bucket: aws.String(s.bucket),
		})
		return err
	}
	return nil
}
