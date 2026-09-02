# Kubernetes-Deployment der Variante v1

Dieses Beispiel ist für Nutzer des Images `pmietlicki/docker-rustdesk-web-client:v1` erhalten geblieben. Passen Sie Domains, Secrets, die Ingress-Klasse und die Storage-Richtlinien vor dem Deployment an Ihre Umgebung an.

```yaml
# 1) Namespace ─────────────────────────────────────────────────────────
apiVersion: v1
kind: Namespace
metadata:
  name: rustdesk

---
# 2) PVC für Daten / Schlüssel ───────────────────────────────────────────
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rustdesk-data
  namespace: rustdesk
  labels:
    app: rustdesk-server
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 50Gi

---
# 3) Deployment hbbs + hbbr (RustDesk Server OSS) ───────────────────────
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rustdesk-server
  namespace: rustdesk
  labels:
    app: rustdesk-server
spec:
  replicas: 1
  selector:
    matchLabels: { app: rustdesk-server }
  template:
    metadata:
      labels: { app: rustdesk-server }
    spec:
      containers:
        - name: hbbs
          image: docker.io/rustdesk/rustdesk-server:latest
          imagePullPolicy: IfNotPresent
          command: ["hbbs"]
          args: ["-k","_"]
          ports:
            - name: nat-port
              containerPort: 21115
              protocol: TCP
            - name: registry-port
              containerPort: 21116
              protocol: TCP
            - name: heartbeat-port
              containerPort: 21116
              protocol: UDP
            - name: web-port
              containerPort: 21118
              protocol: TCP
          livenessProbe:
            tcpSocket: { port: 21115 }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            tcpSocket: { port: 21115 }
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: rustdesk-data
              mountPath: /root

        - name: hbbr
          image: docker.io/rustdesk/rustdesk-server:latest
          imagePullPolicy: IfNotPresent
          command: ["hbbr"]
          args: ["-k","_"]
          ports:
            - name: relay-port
              containerPort: 21117
              protocol: TCP
            - name: client-port
              containerPort: 21119
              protocol: TCP
          livenessProbe:
            tcpSocket: { port: 21117 }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            tcpSocket: { port: 21117 }
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: rustdesk-data
              mountPath: /root

      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: { app: rustdesk-server }
              topologyKey: kubernetes.io/hostname

      volumes:
        - name: rustdesk-data
          persistentVolumeClaim:
            claimName: rustdesk-data

---
# 4) Service LoadBalancer (MetalLB) ──────────────────────────────────────
apiVersion: v1
kind: Service
metadata:
  name: rustdesk-server
  namespace: rustdesk
  labels:
    app: rustdesk-server
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  selector: { app: rustdesk-server }
  ports:
    - name: nat-port
      port: 21115
      targetPort: 21115
      protocol: TCP
    - name: registry-port
      port: 21116
      targetPort: 21116
      protocol: TCP
    - name: heartbeat-port
      port: 21116
      targetPort: 21116
      protocol: UDP
    - name: web-port
      port: 21118
      targetPort: 21118
      protocol: TCP
    - name: relay-port
      port: 21117
      targetPort: 21117
      protocol: TCP
    - name: client-port
      port: 21119
      targetPort: 21119
      protocol: TCP

---
# 5) Deployment Web Client ───────────────────────────────────────────────
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rustdesk-web-client
  namespace: rustdesk
  labels:
    app: rustdesk-web-client
spec:
  replicas: 1
  selector:
    matchLabels: { app: rustdesk-web-client }
  template:
    metadata:
      labels: { app: rustdesk-web-client }
    spec:
      containers:
        - name: web-client
          image: pmietlicki/rustdesk-web-client:v1
          imagePullPolicy: Always
          ports:
            - containerPort: 5000
          env:
            - name: CUSTOM_RENDEZVOUS_SERVER
              value: "rustdesk.test.local"
            - name: RELAY_SERVER
              value: "rustdesk.test.local"
            - name: KEY
              value: "xxxxxxxxxxxxxxxxxxxxxxx"
          livenessProbe:
            httpGet: { path: "/", port: 5000 }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: "/", port: 5000 }
            initialDelaySeconds: 5
            periodSeconds: 10

---
# 6) Service ClusterIP für Web Client ──────────────────────────────────
apiVersion: v1
kind: Service
metadata:
  name: rustdesk-web-client
  namespace: rustdesk
  labels:
    app: rustdesk-web-client
spec:
  type: ClusterIP
  selector: { app: rustdesk-web-client }
  ports:
    - port: 5000
      targetPort: 5000
      protocol: TCP
---
# 7) Einziger Ingress: WSS + HTTPS + Web UI ─────────────────────────────
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rustdesk
  namespace: rustdesk
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
spec:
  tls:
    - hosts: [rustdesk.test.local]
      secretName: rustdesk-server-tls
  rules:
    - host: rustdesk.test.local
      http:
        paths:
          # WebSocket ID server hbbs
          - path: /ws/id
            pathType: Prefix
            backend:
              service: { name: rustdesk-server, port: { name: web-port } }
          # WebSocket relay hbbr
          - path: /ws/relay
            pathType: Prefix
            backend:
              service: { name: rustdesk-server, port: { name: client-port } }
          # Alles Übrige → Web Client
          - path: /
            pathType: Prefix
            backend:
              service: { name: rustdesk-web-client, port: { number: 5000 } }
```
