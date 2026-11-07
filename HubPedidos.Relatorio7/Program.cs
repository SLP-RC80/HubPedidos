using HubPedidos.Relatorio7;
using Microsoft.AspNetCore.Authentication;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);
builder.Host.UseDefaultServiceProvider((_, options) => { options.ValidateOnBuild = true; options.ValidateScopes = true; });

// Apenas demonstracao local em Codespaces. Chaves aleatorias, nao commitadas.
var credenciais = builder.Configuration["R7_CREDENTIALS_FILE"] ??
    Path.Combine(builder.Environment.ContentRootPath, ".secrets", "tokens.env");
builder.Services.AddSingleton(new CredenciaisDidaticas(credenciais));
builder.Services.AddAuthentication("R7").AddScheme<AuthenticationSchemeOptions, ChaveR7Handler>("R7", _ => { });
builder.Services.AddAuthorization();
builder.Services.AddSignalR();
builder.Services.AddScoped<IPedidoAccessService, PedidoAccessService>();
builder.Services.AddScoped<AtualizadorPedidos>();
builder.Services.AddSingleton<IEmissorPedido, EmissorSignalR>();

var banco = builder.Configuration["R7_DATABASE_FILE"] ??
    Path.Combine(builder.Environment.ContentRootPath, ".data", "pedidos.db");
Directory.CreateDirectory(Path.GetDirectoryName(banco)!);
builder.Services.AddDbContext<R7DbContext>(opt => opt.UseSqlite($"Data Source={banco}"));

builder.Services.AddOutputCache(opcoes => opcoes.AddPolicy("CatalogoPublico", policy => policy
    .Expire(TimeSpan.FromMinutes(10))
    .SetVaryByQuery("regiao")
    .Tag("catalogo-status")));

var app = builder.Build();
using (var scope = app.Services.CreateScope()) ExemplosR7.Semear(scope.ServiceProvider.GetRequiredService<R7DbContext>());
app.UseRouting();
app.UseAuthentication();
app.UseAuthorization();
app.UseOutputCache();

app.MapGet("/health", () => Results.Ok(new { modulo = "R7", status = "ok" }));
app.MapHub<PedidosHub>("/hubs/pedidos").RequireAuthorization();

// Apenas dado publico tem Output Cache. GET privado tem ETag, SEM Output Cache.
app.MapGet("/api/publico/catalogo-status", ApiEndpoints.Catalogo)
    .CacheOutput("CatalogoPublico");
app.MapGet("/api/v1/pedidos/{id:guid}", ApiEndpoints.Detalhe).RequireAuthorization();
app.MapPut("/api/v1/pedidos/{id:guid}/status", ApiEndpoints.Alterar).RequireAuthorization();
app.Run();

// Permite testes de API em estudos posteriores sem alterar esta implementacao.
public partial class Program { }
