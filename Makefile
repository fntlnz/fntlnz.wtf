.PHONY: build push localserve

GIT_COMMIT := $(shell git rev-parse HEAD 2> /dev/null || true)
IMAGE := quay.io/fntlnz/fntlnz.wtf:${GIT_COMMIT}

build:
	docker build --build-arg HUGO_SITE_VERSION=${GIT_COMMIT} -t ${IMAGE} .

push:
	docker push ${IMAGE}
	@echo ""
	@echo "Now you only need to deploy the brand new ver!"
	@echo ">> kubectl set image deployment/fntlnzweb -n fntlnzweb fntlnzweb=${IMAGE}"

localserve: build
	docker run --rm -p 8080:80 ${IMAGE}
