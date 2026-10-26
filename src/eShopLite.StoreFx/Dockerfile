FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY ["src/eShopLite.StoreFx/eShopLite.StoreFx.csproj", "src/eShopLite.StoreFx/"]
RUN dotnet restore "src/eShopLite.StoreFx/eShopLite.StoreFx.csproj"

COPY src/eShopLite.StoreFx/ src/eShopLite.StoreFx/
RUN dotnet publish "src/eShopLite.StoreFx/eShopLite.StoreFx.csproj" \
    --configuration Release --no-restore --output /app/publish \
    /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
ENV ASPNETCORE_HTTP_PORTS=8080
# Deployment-only lab: no shared Data Protection storage is provisioned.
ENV Lab06__DisableAntiforgery=true
EXPOSE 8080
COPY --from=build /app/publish .
USER $APP_UID
ENTRYPOINT ["dotnet", "eShopLite.StoreFx.dll"]
