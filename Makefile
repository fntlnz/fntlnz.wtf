.PHONY: build

GIT_COMMIT := $(shell git rev-parse HEAD 2> /dev/null || true)
IMAGE := docker.io/fntlnz/fntlnz.wtf:${GIT_COMMIT}

build:
	docker build -t ${IMAGE} .

push:
	docker push ${IMAGE}
	@echo ""
	@echo "Now you only need to deploy the brand new ver!"
	@echo ">> kubectl set image deployment/fntlnzweb -n fntlnzweb fntlnzweb=${IMAGE}"
